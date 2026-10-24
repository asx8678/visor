// The agent's wakes (Visor.Agent's can_wake?/1 and start_wake/3), proven
// with gdp-wired: `bun install && bun wakes.ts`. Exits 1 when a law fails.
//
// A wake is a prompt the agent starts on its own. Between two of the
// user's prompts, a job's end (or a reviewer's message) may wake it
// Visor.Limits.job_wakeups/0 times, and a monitored job's lines alone
// monitor_wakeups/0 times; Stop or a failed call holds them all.
import {bool, oneOf, proveRule, rule, when} from 'gdp-wired'

const event = oneOf('monitor', 'end', 'prompt', 'stop')
const held = ({e, held}: any) => e.is('prompt').not().and(e.is('stop').or(held))

// As Visor does it: two counts.
const wakes = rule('wakes')
  .inputs({e: event})
  .state({jobWakes: 0, monitorWakes: 0, held: bool.from(false), untold: 0, ends: 0})
  .step(({e, jobWakes, monitorWakes, held: h, untold, ends}) => {
    const fresh = e.is('prompt')
    const jobWake = e.is('end').and(h.not()).and(jobWakes.lt(3))
    const monitorWake = e.is('monitor').and(h.not()).and(monitorWakes.lt(3))
    return {
      jobWakes: when(fresh, 0, when(jobWake, jobWakes.plus(1), jobWakes)),
      monitorWakes: when(fresh, 0, when(monitorWake, monitorWakes.plus(1), monitorWakes)),
      held: held({e, held: h}),
      // Job ends that wait for the user's next prompt, and job ends since it.
      untold: when(fresh, 0, when(e.is('end').and(jobWake.not()), untold.plus(1), untold)),
      ends: when(fresh, 0, when(e.is('end'), ends.plus(1), ends)),
    }
  })

// A job's end waits for the next prompt only after Stop, or when job
// ends themselves have used up the wakes: never because of a monitor.
const law = (r: any) =>
  r.law("a monitor never uses up a job end's wake", ({untold, held, ends}: any) =>
    untold.eq(0).or(held).or(ends.atLeast(4)))

// The bug this rules out, as Visor had it: one count for both,
// so one monitor batch and three job ends left the third untold.
const shared = rule('wakes-shared')
  .inputs({e: event})
  .state({wakes: 0, held: bool.from(false), untold: 0, ends: 0})
  .step(({e, wakes: w, held: h, untold, ends}) => {
    const fresh = e.is('prompt')
    const can = h.not().and(w.lt(3))
    return {
      wakes: when(fresh, 0, when(e.is('monitor').or(e.is('end')).and(can), w.plus(1), w)),
      held: held({e, held: h}),
      untold: when(fresh, 0, when(e.is('end').and(can.not()), untold.plus(1), untold)),
      ends: when(fresh, 0, when(e.is('end'), ends.plus(1), ends)),
    }
  })

// The invariant that makes it inductive (found by gdp-wired's search): a
// job end is either told by a job wake or waits, never lost to a monitor.
const accounted = wakes.law('job wakes and waiting ends add up to the ends', ({jobWakes, untold, ends, held}: any) =>
  held.not().implies(jobWakes.plus(untold).atMost(ends)))

const proven = proveRule(wakes, [law(wakes), accounted], {search: false})
const broken = proveRule(shared, [law(shared)], {search: false})
console.log('wakes:', JSON.stringify(proven))
console.log('shared count (must be refused):', JSON.stringify(broken))
if (!(proven.proven && proven.checked) || broken.proven) process.exit(1)
