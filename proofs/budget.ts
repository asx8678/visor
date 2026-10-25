// A prompt's spending limit (Visor.Agent's over_budget/1, allowance/1 and
// V.agent's affordable?/1), proven with gdp-wired: `bun budget.ts`.
// Exits 1 when a law fails.
//
// Costs are naturals (say, micro-dollars). A model call's cost is at most
// m: Visor can't bound it, so every bound here is in calls' worth. Each
// call's check and its spending are one step; calls in flight at once
// aren't modelled.
import {bool, min, nat, oneOf, proveRule, rule, when} from 'gdp-wired'
import {search} from 'gdp-wired/machine'

// One agent alone: it checks before each model call (over_budget/1), and
// the call's cost comes in after it.
const lone = rule('budget')
  .params({limit: nat, m: nat})
  .inputs({c: nat})
  .assume(({c, m}) => c.atMost(m))
  .state({spent: 0})
  .step(({c, spent, limit}) => ({spent: when(spent.lt(limit), spent.plus(c), spent)}))
const within = lone.law('a prompt spends at most its limit and one call', ({spent, limit, m}) =>
  spent.atMost(limit.plus(m)))

// With a sub-agent, as Visor does it: V.agent gives it what the prompt
// has left (allowance/1, refused at 0 by affordable?/1). The child passes
// each of its calls' cost on to the parent itself, as it comes (Visor.
// Agent's spend/3), and before each call asks the parent what is left
// (budget_limits/1, a call after those casts from the same process, so
// the parent has counted them): the child calls while it is under its
// allowance and the parent's spending, its own included, is under the
// limit. Each of its steps here is that check and its call's cost, as the
// child makes them one after the other. One sub-agent at a time here;
// Visor allows more, each asking the same way, so each may be one call
// past the limit at once (calls in flight together aren't modelled).
const event = oneOf('call', 'spawn', 'childCall', 'childEnd')
const sub = (name: string, live: boolean) => rule(name)
  .params({limit: nat, m: nat})
  .inputs({e: event, c: nat})
  .assume(({c, m}) => c.atMost(m))
  .state({spent: 0, child: bool.from(false), allowance: 0, childSpent: 0})
  .flags(({e, child, spent, limit, allowance, childSpent}) => ({
    call: e.is('call').and(spent.lt(limit)),
    spawn: e.is('spawn').and(child.not()).and(spent.lt(limit)),
    childCall: live
      ? e.is('childCall').and(child).and(childSpent.lt(allowance)).and(spent.lt(limit))
      : e.is('childCall').and(child).and(childSpent.lt(allowance)),
    end: e.is('childEnd').and(child),
  }))
  .step(({c, spent, child, allowance, childSpent, limit, call, spawn, childCall, end}) => ({
    spent: live
      ? when(call.or(childCall), spent.plus(c), spent)
      : when(call, spent.plus(c), when(end, spent.plus(childSpent), spent)),
    child: spawn.or(child.and(end.not())),
    allowance: when(spawn, limit.minus(spent), allowance),
    childSpent: when(spawn.or(end), 0, when(childCall, childSpent.plus(c), childSpent)),
  }))

const withChild = sub('budget-child', true)
// Spent counts the child's calls as they come, so it is the two's total.
const childWithin = withChild.law('a prompt and its sub-agent spend at most the limit and one call',
  ({spent, limit, m}) => spent.atMost(limit.plus(m)))

// The broken variant: the child's spending reached the parent only when
// it ended, and nothing held the child to what the parent spent meanwhile,
// so the two together passed the limit by up to the limit again.
const atEnd = sub('budget-child-at-end', false)
const atEndWithin = atEnd.law('counted at the end, a prompt and its sub-agent spend at most the limit and one call',
  ({spent, childSpent, limit, m}) => spent.plus(childSpent).atMost(limit.plus(m)))

// A parent that doesn't answer in time (budget_limits/1 waits 1 s: the
// parent is busy, or its session is ending): the child holds to its last
// answer, kept as a cap on its own spending (`cap`: what it had spent
// then and what the parent had left), so less what it has spent since.
// Before any answer it holds to its allowance, which the parent gave it
// at the spawn, an answer too. `since` is what the parent spent itself
// since that answer: only that can pass the limit, beside one call. With
// one sub-agent here; in Visor the others' spending since counts too.
// The broken variant falls back to the allowance the child started with,
// as Visor did, so what the parent spent before its last answer passes
// the limit as well.
const slowEvent = oneOf('call', 'spawn', 'childCall', 'childUnanswered', 'childEnd')
const slow = (name: string, keepsAnswer: boolean) => rule(name)
  .params({limit: nat, m: nat})
  .inputs({e: slowEvent, c: nat})
  .assume(({c, m}) => c.atMost(m))
  .state({spent: 0, child: bool.from(false), allowance: 0, childSpent: 0, cap: 0, since: 0})
  .flags(({e, child, spent, limit, allowance, childSpent, cap}) => ({
    call: e.is('call').and(spent.lt(limit)),
    spawn: e.is('spawn').and(child.not()).and(spent.lt(limit)),
    answered: e.is('childCall').and(child).and(childSpent.lt(allowance)).and(spent.lt(limit)),
    unanswered: e.is('childUnanswered').and(child)
      .and(childSpent.lt(keepsAnswer ? min(allowance, cap) : allowance)),
    end: e.is('childEnd').and(child),
  }))
  .step(({c, spent, child, allowance, childSpent, cap, since, limit, call, spawn, answered, unanswered, end}) => ({
    spent: when(call.or(answered).or(unanswered), spent.plus(c), spent),
    child: spawn.or(child.and(end.not())),
    allowance: when(spawn, limit.minus(spent), allowance),
    childSpent: when(spawn.or(end), 0, when(answered.or(unanswered), childSpent.plus(c), childSpent)),
    cap: when(spawn, limit.minus(spent), when(answered, childSpent.plus(limit.minus(spent)), cap)),
    since: when(spawn.or(answered), 0, when(call, since.plus(c), since)),
  }))

const withSlow = slow('budget-child-slow-parent', true)
const slowWithin = withSlow.law(
  'with a slow parent, a prompt and its sub-agent pass the limit by one call and what the parent spent since its last answer',
  ({spent, limit, m, since}) => spent.atMost(limit.plus(m).plus(since)))
// What makes it hold: the parent's spending besides the child's has grown
// by `since` from the answer, when it had left what `cap` allows.
const slowCap = withSlow.law('the last answer leaves the child no more than the parent had left then',
  ({child, spent, cap, limit, since, childSpent}) =>
    child.not().or(spent.plus(cap).atMost(limit.plus(since).plus(childSpent))))

const failOpen = slow('budget-child-slow-parent-fails-open', false)
const failOpenWithin = failOpen.law(
  'falling back to its allowance, a prompt and its sub-agent pass the limit by one call and what the parent spent since its last answer',
  ({spent, limit, m, since}) => spent.atMost(limit.plus(m).plus(since)))

const fail: string[] = []
const expect = (name: string, ok: boolean, v: unknown) => {
  console.log(`${ok ? 'ok' : 'FAILED'}  ${name}: ${JSON.stringify(v)}`)
  if (!ok) fail.push(name)
}

const a = proveRule(lone, [within], {search: false})
expect('a lone prompt stays within its limit and one call', a.proven && a.checked, a)

const c = proveRule(withChild, [childWithin], {search: false})
expect('with a sub-agent: at most the limit and one call', c.proven && c.checked, c)

const gap = search(atEnd.machine, atEndWithin, 8)
expect('counted at the end (must be refused): the two pass limit + one call, with a run', !!gap, gap)

const s = proveRule(withSlow, [slowWithin, slowCap], {search: false})
expect('with a slow parent: at most the limit, one call and what the parent spent since its last answer', s.proven && s.checked, s)

// Values up to 3: the run needs a parent that spent more than a call
// before the child's last answer, and still had some left (limit 3, m 2).
const open = search(failOpen.machine, failOpenWithin, 5, 3)
expect('a slow parent, the child falling back to its allowance (must be refused): past that, with a run', !!open, open)

if (fail.length) process.exit(1)
