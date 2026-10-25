// The agent's wakes (Visor.Agent.Wakes, and the handle_info(:wake, _)
// that calls it), proven with gdp-wired: `bun wakes.ts` (or `mix
// visor.proofs`). Exits 1 when a law fails.
//
// A wake is a prompt the agent starts on its own. Between two of the
// user's prompts, a job's end (or a supervisor's message) may wake it
// jobLimit times (Visor.Limits.job_wakeups/0), and a monitored job's lines
// alone monitorLimit times (monitor_wakeups/0); Stop or a failed call holds
// them all. Notices that come close together wake it once: they wait for
// the batch timer, and a batch that holds a job's end counts as a job's
// wake. A notice that comes while the agent runs goes with its tool calls'
// results, or waits until it is idle.
//
// Left out, since each only holds a wake back and counts nothing: /jobs
// wake off, Visor.ModelHealth and Visor.Alarms.
import {bool, nat, oneOf, proveRule, proveSteps, rule, when} from 'gdp-wired'
import {search} from 'gdp-wired/machine'

export const events = ['lines', 'end', 'fire', 'results', 'answer', 'stop', 'prompt'] as const
// lines:   a monitored job printed lines its monitor looks for
// end:     a job ended (or a supervisor's message came)
// fire:    the batch timer went off
// results: the running tool calls' results went to the model, with the notices
// answer:  the running prompt (the user's or a wake) ended with an answer
// stop:    the running prompt was stopped, or its model call failed
// prompt:  the user sent a prompt
const event = oneOf(...events)

// The parts both counts share: what waits to be told, whether the agent
// runs, and the ghost state the law reads (`endWakes`: wakes since the
// user's prompt that told of a job's end; `missed`: a batch with a job's
// end found the agent idle and didn't wake it).
const base = {
  held: bool.from(false), idle: bool.from(true),
  pendEnd: bool.from(false), pendLines: bool.from(false),
  endWakes: 0, missed: bool.from(false),
}

const common = (env: any, wake: any) => {
  const {e, held, idle, pendEnd, pendLines, endWakes, missed} = env
  const fresh = e.is('prompt').and(idle)
  const told = fresh.or(wake).or(e.is('results').and(idle.not()))
  return {
    held: fresh.not().and(held.or(e.is('stop').and(idle.not()))),
    idle: fresh.or(wake).not().and(idle.or(e.is('answer')).or(e.is('stop'))),
    pendEnd: told.not().and(pendEnd.or(e.is('end'))),
    pendLines: told.not().and(pendLines.or(e.is('lines'))),
    endWakes: when(fresh, 0, when(wake.and(pendEnd), endWakes.plus(1), endWakes)),
    missed: fresh.not().and(missed.or(e.is('fire').and(idle).and(pendEnd).and(wake.not()))),
  }
}

// As Visor does it: two counts.
export const wakes = rule('wakes')
  .params({jobLimit: nat, monitorLimit: nat})
  .inputs({e: event})
  .state({...base, jobWakes: 0, monitorWakes: 0})
  .flags(({e, held, idle, pendEnd, pendLines, jobWakes, monitorWakes, jobLimit, monitorLimit}) => ({
    wake: e.is('fire').and(idle).and(held.not()).and(
      pendEnd.and(jobWakes.lt(jobLimit)).or(pendEnd.not().and(pendLines).and(monitorWakes.lt(monitorLimit)))),
  }))
  .step((env) => {
    const {e, idle, wake, pendEnd, jobWakes, monitorWakes} = env
    const fresh = e.is('prompt').and(idle)
    return {
      ...common(env, wake),
      jobWakes: when(fresh, 0, when(wake.and(pendEnd), jobWakes.plus(1), jobWakes)),
      monitorWakes: when(fresh, 0, when(wake.and(pendEnd.not()), monitorWakes.plus(1), monitorWakes)),
    }
  })

// A batch with a job's end that found the agent idle waits for the next
// prompt only after Stop, or once job ends have had their wakes: never
// because monitors woke the agent.
const law = (r: any) =>
  r.law("a monitor never uses up a job end's wake", ({missed, held, endWakes, jobLimit}: any) =>
    missed.implies(held.or(endWakes.atLeast(jobLimit))))

// The invariant that makes it inductive: the job count is the ghost count.
const counted = wakes.law('the job count counts the wakes that told of an end',
  ({jobWakes, endWakes}) => jobWakes.eq(endWakes))
const jobBound = wakes.law('job ends wake the agent at most jobLimit times',
  ({jobWakes, jobLimit}) => jobWakes.atMost(jobLimit))
const monitorBound = wakes.law('monitors wake the agent at most monitorLimit times',
  ({monitorWakes, monitorLimit}) => monitorWakes.atMost(monitorLimit))
const heldStays = wakes.stepLaw('a held agent wakes for nothing but the user',
  ({held, idle, e}, after) => held.and(idle).and(e.is('prompt').not()).implies(after.idle))
const runningStays = wakes.stepLaw('a running agent never wakes',
  ({idle, jobWakes, monitorWakes}, after) =>
    idle.not().implies(after.jobWakes.eq(jobWakes).and(after.monitorWakes.eq(monitorWakes))))

// The bug this rules out, as Visor had it: one count for both, so one
// monitor batch and three job ends left the third untold.
const shared = rule('wakes-shared')
  .params({jobLimit: nat, monitorLimit: nat})
  .inputs({e: event})
  .state({...base, wakes: 0})
  .flags(({e, held, idle, pendEnd, pendLines, wakes: w, jobLimit}) => ({
    wake: e.is('fire').and(idle).and(held.not()).and(pendEnd.or(pendLines)).and(w.lt(jobLimit)),
  }))
  .step((env) => {
    const {e, idle, wake, wakes: w} = env
    return {...common(env, wake), wakes: when(e.is('prompt').and(idle), 0, when(wake, w.plus(1), w))}
  })

const proven = proveSteps(wakes, [law(wakes), counted, jobBound, monitorBound], [heldStays, runningStays], {search: false})
const broken = proveRule(shared, [law(shared)], {search: false})
console.log('wakes:', JSON.stringify(proven))
// Not only not inductive: a real run from the start breaks it.
const bug = search(shared.machine, law(shared), 8)
console.log('shared count (must be refused):', JSON.stringify(broken), 'run:', JSON.stringify(bug))
if (!(proven.proven && proven.checked) || broken.proven || !bug) process.exit(1)
