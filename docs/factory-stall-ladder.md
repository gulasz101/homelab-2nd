# Factory stall ladder (GUL-2037 phase 4)

What the factory does when a stage fails, and who it wakes. Contract:
`agents/factory/ENGINE.md`; stage config: `agents/factory/engine.json`.

## When a stage fails

A stage gets up to 3 attempts. Each failed attempt is recorded, and the next
prompt carries the previous failure. When the same failure comes back twice,
the next prompt adds `SAME FAILURE`, so the agent stops repeating the fix that
did not work and reads the reason again.

## The Investigator

After 3 failed attempts the stage goes to a read-only Investigator, model
`deepseek-v4-pro-ollama`. It reads the attempts and returns exactly one verdict:

- `TEST-WRONG`: the test is wrong, so the red stage rewrites the test and the
  ladder starts again.
- `CODE-WRONG`: the code is wrong, so the Builder Pro gets one more attempt.
- `SPEC-WRONG` or `ENV`: the order stops and wakes Claude Code, because the
  work order or the machine is the problem, not the agent.

One order gets at most 2 investigations. A third rise up the ladder is a stall.

## When the owner is asked

A final stall wakes Claude Code with one `[stall]` issue on the board, at most
3 a day. That issue carries the attempts, the verdicts and the stage, so the
owner can decide without replaying the runs. The owner is asked only for
SAFETY gates: merges that need a human, secrets, and anything the factory may
not touch. The factory never waits on the owner for a normal stage.
