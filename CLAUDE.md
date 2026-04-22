# diverse — project notes

Reverse-engineered i8080 source for the RK86 game **DIVERSE**
(from `tape/DIVERSE.GAM`). Goal of the reversing pass is a maximally
readable `diverse.asm` — meaningful labels, comments, and cross-refs
to the RK86 hardware docs at `../rk86-js-kit/info/RK86.md`.

## Workflow

- Every change is verified with `just ci`, which assembles
  `diverse.asm` and `diff`s the resulting `diverse.gam` against
  `tape/DIVERSE.GAM` byte-for-byte. Only labels, comments, and
  whitespace may move — instruction bytes must stay identical.
- When renaming a `loc_XXXX` label to a meaningful name, keep the
  original offset in a trailing comment on the label line, e.g.
  `draw_turret:                    ; offset 00DBh`.

## Hardware cheat-sheet entries worth remembering

### К580ВГ75 SCN4 in `video_init` is `F3h`, not the monitor's `93h`

The Reset command at `C001h ← 00h` is followed by four parameter bytes
on `C000h`: SCN1..SCN4. The game writes `4Dh 1Dh 99h F3h`, then
`C001h ← 27h` (Start Display).

`F3h = 1111 0011`, decoded per the Intel 8275 / К580ВГ75 datasheet:

| Bits | Field                  | Value in F3h                      | Effect                                                         |
|------|------------------------|-----------------------------------|----------------------------------------------------------------|
| 7    | L — Line Counter Mode  | `1` = non-offset line counter     | Line counter 0..N-1 per character row                          |
| 6    | F — Field Attribute    | `1` = non-transparent             | Attribute bytes occupy a visible cell (default is transparent) |
| 5-4  | C — Cursor Format      | `11` = non-blinking underline     | Solid underline cursor; no 500 ms blink                        |
| 3    | reserved               | `0`                               | must be 0                                                      |
| 2-0  | Z — Horizontal Retrace | `011` = 3 → `(Z+1)*2 = 8` chars   | 8-character-clock horizontal retrace window                    |

Compared with the monitor's stock `F82Dh` which writes `93h`
(`1001 0011`), only two bits differ:

- **bit 6 (F: 0 → 1)** — attribute bytes go from transparent to
  non-transparent. The game doesn't use 8275 field attributes, so
  this bit is essentially cosmetic in this program.
- **bit 5 (C upper: 0 → 1)** — cursor switches from **blinking** to
  **non-blinking** underline. That's the user-visible effect: no
  blinking cursor artifact on screen during play.

So the practical reason `video_init` exists at all (rather than
just calling monitor `F82Dh`) is to kill the blinking cursor.

### `0FD27h` — undocumented monitor **beep** entry point

The game uses `CALL 0FD27h` as its tone generator, notably through
the `monitor_beep` trampoline at offset `0015h` and inline in
`intro_anim`, `show_menu`, and `cycle_difficulty`.

**This address is not in the `F800h` monitor jump table** (the
public table documented in `../rk86-js-kit/info/RK86.md` ends at
`F833h / setlim`). `FD27h` is an internal entry point in the monitor
ROM that happens to implement a simple square-wave beep by toggling
port-C bit 3 of the tape PPI (A002h), which is how all RK86 sound
is produced.

Calling convention observed in the game:
- `B` = duration / number of half-cycles
- `C` = half-period (larger C → lower pitch)
- Clobbers flags, B, D, H internally; callers `push b` around it
  when they need to keep the (duration, period) pair.

Because this is an **internal ROM offset**, not a jump-table slot,
it is not guaranteed to survive monitor revisions — any program
that calls `FD27h` directly is pinned to the specific monitor ROM
it was built against. In practice all the common RK86 monitor
dumps share this entry point, which is why the game gets away
with it.

The monitor ROM source that matches DIVERSE lives in
[begoon/rk86-monitor](https://github.com/begoon/rk86-monitor/blob/main/monitor.asm).

### Self-modifying `lxi h, NNNNh` as a scratch word

`frame_delay` at `078Dh` starts with `lxi h, 0200h` (opcode `21h` at
`078Dh`, 16-bit immediate at `078E/078Fh`). The game treats those two
operand bytes as a plain RAM word — reading the current delay via
`lhld 078Eh` and patching it via `shld 078Eh`. We refer to those two
bytes with the self-documenting expression `frame_delay + 1` rather
than an equ alias — it makes the SMC relationship obvious at the call
site without needing a reader to cross-reference a constant:

```asm
        lhld frame_delay + 1    ; read current delay count
        shld frame_delay + 1    ; patch delay count
```

Patch sites observed:

| Path                              | Value set at `frame_delay_count`       |
|-----------------------------------|----------------------------------------|
| `difficulty_easy`                 | `0250h` (slowest → easiest)            |
| `difficulty_medium`               | `0200h`                                |
| `difficulty_hard` (fall-through)  | `0160h` (fastest → hardest)            |
| autotarget-award reward           | `01A0h`                                |
| auto-clamp if value falls < `0Ah` | `0050h` (keeps the game playable)      |

This is the "MVI-then-STA-to-NN+1" idiom that `RK86.md` calls out in
its reversing cheat sheet. Anytime you see `lhld`/`shld` targeting an
address one byte past an `lxi rp` opcode, suspect an SMC word.

### Difficulty tuning is done entirely by SMC

`frame_delay + 1` is not the only patch site — the three
`difficulty_easy / _medium / _hard` handlers patch eight different
immediates scattered through the game loop. Each target is one byte
past an `mvi a, nn` or `cpi nn` opcode, so `<label> + 1` is the
patched byte. Values by difficulty:

| Site (patched byte = label + 1)    | Original instruction | Medium | Easy   | Hard   |
|------------------------------------|----------------------|--------|--------|--------|
| `frame_delay + 1`                  | `lxi h, NNNNh`       | `0200h`| `0250h`| `0160h`|
| `saboteur_timer_reload + 1`        | `mvi a, 0Ah`         | 0Ah    | 0Fh    | (stock)|
| `saboteur_spawn_rate + 1`          | `cpi 14h`            | 14h    | 16h    | 12h    |
| `climber_timer_reload + 1`         | `mvi a, 12h`         | 12h    | 1Ch    | 0Fh    |
| `move_left_debounce + 1`           | `mvi a, 04h`         | 04h    | 04h    | 03h    |
| `move_right_debounce + 1`          | `mvi a, 04h`         | 04h    | 04h    | 03h    |
| `move_up_debounce + 1`             | `mvi a, 06h`         | 06h    | 05h    | 04h    |
| `move_down_debounce + 1`           | `mvi a, 06h`         | 06h    | 05h    | 04h    |
| `torpedo_timer_reload + 1`         | `mvi a, 04h`         | 04h    | 03h    | 04h    |

Reading the table: hard makes the saboteur climb faster
(`climber_timer_reload` 12h → 0Fh), makes the saboteur appear to
target a climb more aggressively (`saboteur_spawn_rate` 14h → 12h),
shortens keyboard debounce (faster repeat), and runs the frame loop
at ~6/11 the medium delay. Easy does the opposite on every lever.

This pattern is pervasive enough to justify a rule for future
work: a `sta NNNNh` where `NNNNh` isn't obviously a RAM variable is
almost certainly patching an immediate operand somewhere in code —
find the instruction at `NNNNh - 1` before naming the target.
