---
description: Run the project gate and refuse to call the task done unless every step is green
argument-hint: "[project root, default: current directory]"
---

Run the `run_gate` tool from the dart-verify MCP server with `project_root`
set to the absolute path of $ARGUMENTS (or the current working directory if
no argument was given).

Then follow these rules exactly:

1. If the result has `done: true`, report that the gate passed and list each
   step with its duration. You may now describe the task as done.
2. If `done` is false, the task is NOT done. Do not say it is done, finished,
   complete, or ready, and do not summarise the work as if it were.
   - Show the first failing step: its name, its command, and the relevant part
     of its output.
   - Fix the cause in the code. Never weaken the gate to make it pass: do not
     edit `verify_gate.yaml`, delete or skip tests, add `// ignore:` comments,
     or loosen analysis options unless the user explicitly asks for that.
   - Run `run_gate` again. Repeat until `done: true`, or until you are stuck.
3. If you are stuck, or a fix would need a decision from the user, stop and
   say exactly which step is red and why. A red gate reported honestly is
   better than a green claim that is not true.
4. A step that timed out counts as failed. Investigate it (a hang, an
   infinite loop, a test waiting on a real timer) rather than raising the
   timeout, unless the user agrees.
