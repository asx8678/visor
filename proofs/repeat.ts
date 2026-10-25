// The repeat guard (Visor.Agent's repeat/2 and start_next_tool/1), proven
// with gdp-wired: `bun repeat.ts`. Exits 1 when a law fails.
//
// The agent counts a script run again unchanged, back to back: from the
// warn-th (Visor.Limits.repeat_warn/0, 3) its result carries a warning,
// and from the block-th (repeat_block/0, 6) it isn't run. A refused script
// still counts, and a prompt (the user's or a wake) starts afresh.
import {bool, nat, oneOf, proveRule, rule, when} from 'gdp-wired'
import {search} from 'gdp-wired/machine'

const event = oneOf('script', 'prompt')

const guard = (name: string, countsRefused: boolean) =>
  rule(name)
    .params({block: nat})
    .inputs({e: event, same: oneOf('same', 'other')})
    // count: repeat/2's count. Ghosts: ran, identical scripts in a row that
    // ran; begun, a script came since the prompt.
    .state({count: 0, ran: 0, begun: bool.from(false)})
    .flags(({e, same, count, block}) => ({
      blocked: e.is('script').and(when(same.is('same').and(count.gt(0)), count.plus(1), 1).atLeast(block)),
    }))
    .step(({e, same, count, ran, begun, blocked}) => {
      const script = e.is('script')
      const next = when(same.is('same').and(count.gt(0)), count.plus(1), 1)
      const counted = countsRefused ? next : when(blocked, 0, next)
      return {
        count: when(script, counted, 0),
        ran: when(script, when(blocked, ran, when(same.is('same').and(begun), ran.plus(1), 1)), 0),
        begun: script,
      }
    })

// As Visor does it: a refused script counts too.
const shipped = guard('repeat', true)
const law = (r: any) =>
  r.law('no more than block - 1 identical scripts in a row run', ({ran, block}: any) =>
    ran.plus(1).atMost(block).or(ran.eq(0)))
const helper = shipped.law('the ones that ran are at most the count', ({ran, count}) => ran.atMost(count))
const begun = shipped.law('a count is a script since the prompt', ({count, begun}) => begun.or(count.eq(0)))

// The bug it rules out: a refusal that starts the count afresh lets the
// next identical script run, and the loop go on.
const resetting = guard('repeat-resetting', false)

const proven = proveRule(shipped, [law(shipped), helper, begun], {search: {ms: 20000}})
const broken = proveRule(resetting, [law(resetting)], {search: false})
const run = search(resetting.machine, law(resetting), 10)
console.log('repeat:', JSON.stringify(proven))
console.log('resetting (must be refused):', JSON.stringify(broken), 'run:', JSON.stringify(run))
if (!(proven.proven && proven.checked) || broken.proven || !run) process.exit(1)
