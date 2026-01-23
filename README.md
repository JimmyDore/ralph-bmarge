# ralph-bma~~d~~rge

> *"Me fail sprint? That's unpossible!"* - Ralph Wiggum, probably

<p align="center">
  <img src="assets/special-area-simpsons.gif" alt="Marge Simpson" width="300"/>
  <br/><br/>
  <strong><em>Ralph, be Marge.</em></strong>
</p>

---

**What happened here?**

Remember [ralph](https://github.com/snarktank/ralph)? The autonomous dev loop everyone loves? Well, Ralph went to therapy, got his life together, and became **Marge** - the most organized Simpson.

Now he runs [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) sprints while you sleep. Or eat donuts. Or both.

| Before | After |
|--------|-------|
| *"I'm helping!"* | *"The sprint is done, sweetie."* |
| Mass chaos | Organized chaos |
| ralph | ralph-bma~~d~~rge |

## What It Does

Ralph-bmarge automates the boring parts of BMAD sprints so you can focus on the fun stuff (complaining about JIRA):

1. **Finds** the next story in `sprint-status.yaml` (status: `ready-for-dev`, `in-progress`, or `review`)
2. **Executes** `/bmad:bmm:workflows:dev-story` until status becomes `review`
3. **Executes** `/bmad:bmm:workflows:code-review` until status becomes `done`
4. **Repeats** for the next story until all stories are complete

## Key Features

| Feature | Description |
|---------|-------------|
| **File-based watchdog** | Monitors `sprint-status.yaml` for status changes (not Claude output) |
| **Session management** | Uses `--session-id` / `--resume` to maintain context within a workflow |
| **AI-in-the-loop fixer** | Auto-launches repair agent when stuck loops detected |
| **Cost & Time tracking** | Tracks cost and duration per story with sprint totals |
| **Webhook notifications** | Slack/Discord notifications on story completion and sprint end |
| **Sprint reports** | Auto-generates markdown reports with full statistics |
| **Sound notifications** | Optional sound alert when sprint completes (macOS/Linux) |
| **Two-condition safety** | Only proceeds when BOTH: Claude has stopped AND status has changed |

## Prerequisites

### 1. BMAD Method (Required)

You must have the [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) installed at the root of your project:

```bash
# Clone BMAD Method into your project root
cd your-project
git clone https://github.com/bmad-code-org/BMAD-METHOD .bmad

# Or add as submodule
git submodule add https://github.com/bmad-code-org/BMAD-METHOD .bmad
```

Make sure you have:
- A valid `_bmad-output/implementation-artifacts/sprint-status.yaml` file
- Story files in `_bmad-output/implementation-artifacts/` directory
- BMAD workflows configured and working

### 2. Claude Code CLI

```bash
# Install Claude Code CLI
npm install -g @anthropic-ai/claude-code

# Authenticate
claude auth
```

### 3. System Dependencies

```bash
# macOS
brew install jq

# Linux (Debian/Ubuntu)
sudo apt install jq expect bc
```

| Dependency | Purpose | Usually Pre-installed |
|------------|---------|----------------------|
| `jq` | JSON parsing | No |
| `expect` | Interactive prompt handling | Yes (macOS) |
| `bc` | Cost calculations | Yes |

## Installation

```bash
# Clone ralph-bmarge into your project
cd your-project
git clone https://github.com/s3d1K0/ralph-bmarge

# Make executable
chmod +x ralph-bmarge/ralph-bmarge.sh
```

## Usage

```bash
# Run until all stories complete (default - infinite mode)
./ralph-bmarge/ralph-bmarge.sh

# Limit to N iterations
./ralph-bmarge/ralph-bmarge.sh --max-iterations 10
./ralph-bmarge/ralph-bmarge.sh 10  # shorthand

# Debug mode - full visibility of prompts and output
./ralph-bmarge/ralph-bmarge.sh --debug

# Dry-run mode (simulation, no Claude calls)
./ralph-bmarge/ralph-bmarge.sh --dry-run

# Validate detection (check stories without running)
./ralph-bmarge/ralph-bmarge.sh --validate

# With Slack/Discord webhook notifications
./ralph-bmarge/ralph-bmarge.sh --webhook "https://hooks.slack.com/services/XXX"

# With sound notification on completion
./ralph-bmarge/ralph-bmarge.sh --notify-sound

# Combine flags
./ralph-bmarge/ralph-bmarge.sh --debug --max-iterations 5

# Show help
./ralph-bmarge/ralph-bmarge.sh --help
```

## Notifications & Reporting

### Webhook Notifications

Send notifications to Slack or Discord when stories complete:

```bash
# Slack
./ralph-bmarge/ralph-bmarge.sh --webhook "https://hooks.slack.com/services/T00/B00/XXX"

# Discord
./ralph-bmarge/ralph-bmarge.sh --webhook "https://discord.com/api/webhooks/XXX/YYY"
```

Notifications are sent:
- When each story is completed (with duration and cost)
- When the entire sprint is complete
- When max iterations limit is reached

### Sprint Reports

A markdown report is automatically generated at the end of each run:

```
ralph-bmarge/sprint-report-2026-01-22-1430.md
```

Report includes:
- Total stories completed
- Total duration and cost
- Average cost per story
- Per-story breakdown with timing and costs
- Configuration used

### Cost & Time Tracking

Stats are displayed after each story and summarized at the end:

```
Story 9-2-magic-link-authentication: done
  |-- Duration: 8m 32s
  |-- Cost: $3.05

+---------------------------------------------------------------+
|                      SPRINT STATISTICS                        |
+---------------------------------------------------------------+
|  Stories Completed:  5
|  Total Duration:     47m 23s
|  Claude Time:        42m 15s
|  Total Cost:         $15.47
|  Avg Cost/Story:     $3.09
|  Avg Time/Story:     8m 27s
+---------------------------------------------------------------+
```

## Validate Mode

Before running, use `--validate` to check story detection:

```
$ ./ralph-bmarge/ralph-bmarge.sh --validate

=== Stories by Status ===

[ready-for-dev] (2 stories)
  - 9-1-new-feature (Epic 9)
  - 9-2-another-feature (Epic 9)

[done] (31 stories)
  - 1-1-monorepo-initialization-ci (Epic 1)
  ...

=== Detection Test ===
Next story: 9-1-new-feature
Epic: 9
Status: ready-for-dev
Story file: .../9-1-new-feature.md
File exists: yes

=== Epic Summary ===
  Epic 1: done (4/4 stories done)
  Epic 9: in-progress (0/2 stories done)
```

## Workflow Diagram

```
                         RALPH-BMARGE MAIN LOOP
                                    |
                                    v
                    +-------------------------------+
                    |  Read sprint-status.yaml      |
                    |  Find next story with status: |
                    |  ready-for-dev | in-progress  |
                    |  | review                     |
                    +-------------------------------+
                                    |
                    +---------------+---------------+
                    |                               |
                    v                               v
        +---------------------+         +---------------------+
        |  No stories found   |         |  Story found        |
        |  EXIT: COMPLETE     |         |                     |
        +---------------------+         +---------------------+
                                                    |
                                                    v
                              +-------------------------------------+
                              |  PHASE 1: dev-story                 |
                              |  (if status = ready-for-dev         |
                              |   or in-progress)                   |
                              +-------------------------------------+
                                                    |
                                                    v
                              +-------------------------------------+
                              |  Claude executes workflow           |
                              |  until status = review              |
                              +-------------------------------------+
                                                    |
                                                    v
                              +-------------------------------------+
                              |  PHASE 2: code-review               |
                              |  (status = review)                  |
                              +-------------------------------------+
                                                    |
                                                    v
                              +-------------------------------------+
                              |  Claude executes review             |
                              |  until status = done                |
                              +-------------------------------------+
                                                    |
                                                    v
                              +-------------------------------------+
                              |  Story DONE -> Next iteration       |
                              |  (back to top, find next story)     |
                              +-------------------------------------+
```

## AI-in-the-Loop: Fixer Agent

Ralph-bmarge includes an **AI-in-the-loop** self-repair mechanism. When a stuck loop is detected (status unchanged after N continues), instead of aborting, it launches a **Fixer Agent** - a separate Claude session tasked with diagnosing and fixing the problem.

```
+-------------------------------------------------------------+
|  STUCK DETECTED (10 stale continues)                        |
|  Status: ready-for-dev | Expected: review                   |
+-------------------------------------------------------------+
                            |
                            v
+-------------------------------------------------------------+
|  FIXER AGENT (new Claude session)                           |
|                                                             |
|  - Reads story file to verify work completion               |
|  - Reads sprint-status.yaml current state                   |
|  - Updates YAML if work is actually done                    |
|  - Reports what went wrong                                  |
+-------------------------------------------------------------+
                            |
              +-------------+-------------+
              |                           |
           FIXED                       FAILED
              |                           |
              v                           v
     Resume main loop              Abort + Alert
     (auto-recovered!)          (manual fix needed)
```

Configure the threshold with `--max-stale N` (default: 10).

## Sprint Status Format

Ralph-bmarge expects `sprint-status.yaml` in this format:

```yaml
development_status:
  epic-1: done
  1-1-story-name: ready-for-dev   # <- Ralph picks this up
  1-2-another-story: done
  2-1-next-story: in-progress     # <- Or this
```

Valid statuses that Ralph processes:
- `ready-for-dev` -> Triggers dev-story
- `in-progress` -> Continues dev-story
- `review` -> Triggers code-review
- `done` -> Skipped (complete)

## Configuration

Edit variables at the top of `ralph-bmarge.sh`:

```bash
MAX_ITERATIONS=10       # Max stories to process in one run
MAX_CONTINUES=20        # Max "continue" attempts per workflow phase
MAX_STALE_CONTINUES=10  # Abort if status unchanged after N continues
```

## Troubleshooting

### "expect not found"
```bash
# macOS (usually pre-installed)
which expect

# Linux
sudo apt install expect
```

### "sprint-status.yaml not found"
Ensure BMAD is configured and you've run `/bmad:bmm:workflows:sprint-planning`.

### Claude hangs or doesn't respond
- Check Claude CLI is authenticated: `claude --version`
- Try running Claude manually first: `claude`
- Check for pending prompts that don't match expect patterns

### Stories stuck in "in-progress"
The workflow might have failed. Check the story file for errors or run the workflow manually:
```bash
claude
> /bmad:bmm:workflows:dev-story
```

## Comparison with Original Ralph

| Feature | Original Ralph | ralph-bmarge |
|---------|---------------|------------|
| Target | Generic tasks | BMAD workflows |
| Status detection | Parses Claude output | Watches YAML files |
| Commands | Generic prompts | BMAD workflows |
| Session mgmt | Basic | UUID-based with resume |
| Auto-response | Yes only | Yes + "continue" for text |
| Self-repair | No | AI Fixer Agent |
| Cost tracking | No | Yes |
| Webhooks | No | Slack/Discord |

## Credits

- Original [ralph](https://github.com/snarktank/ralph) by snarktank - the OG chaos agent
- [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) by bmad-code-org - the method behind the madness
- Matt Groening - for creating the most relatable dysfunctional family in TV history

## License

MIT - Same as original Ralph. See [LICENSE](LICENSE).

---

<p align="center">
  <em>"Ralph, be Marge!"</em>
  <br/>
  Built for developers who want their sprints to run themselves.
  <br/><br/>
  <sub>No Simpsons were harmed in the making of this software. Except Ralph's dignity.</sub>
</p>
