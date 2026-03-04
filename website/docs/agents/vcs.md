# Next-Gen Version Control

Git is too slow for agent-speed development. Fundamental rethink needed.

## Core Principles

- **No branches, no merging** — everyone edits the same codebase live
- **Checkpoints instead of commits** — save points, not a DAG
- **Real-time collaborative editing** — Google Docs for code, powered by CRDTs
- **Reputation-based write access** — earned trust determines what you can change
- **Instant propagation** — verified changes available to everyone immediately
- **Agent-first reconciliation** — conflicts resolved automatically by AI, not manually by humans

## How It Works

1. Multiple people and agents edit code simultaneously (CRDT-based sync)
2. A reconciliation agent watches all change streams in real-time
3. Most conflicts resolve automatically — textual proximity doesn't mean semantic conflict
4. The agent makes its own decisions — doesn't default to human code review
5. Only raises architectural or design questions to humans (and doesn't show them code, just the question)
6. When a change works (agent-verified or user-confirmed), it becomes the next checkpoint
7. Checkpoints propagate immediately to all participants

## Access Control

The same trust tiers from the [Trust & Reputation](trust.md) system apply here:

- **New contributor** — changes go through verification before checkpoint
- **Trusted contributor** — changes checkpoint immediately
- **Maintainer** — can roll back anyone's checkpoints, set trust levels
- **Code visibility** — configurable per-person. Publish to specific people or publicly.

Trust gates access. Competence gates autonomy. A trusted person who's incompetent in a specific domain still gets their changes verified in that domain.

## Why GitHub Can't Do This

- Git's model is fundamentally turn-based: commit, push, PR, review, merge
- PRs take hours or days — agents work in seconds
- Merge conflicts are a solved problem when an agent watches changes in real-time
- GitHub Actions and CI pipelines are batch-oriented, not real-time
- The entire PR workflow assumes human-speed review cycles

The tools we have were built for a world where development was slow. That world is over.
