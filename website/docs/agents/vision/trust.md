# Trust & Reputation

A unified trust system that governs both agent-to-agent communication and collaborative code editing. Cryptographically verifiable, decentralized, with no central authority.

## Trust Tiers

From most open to most restricted:

| Tier | Description | Risk |
|------|-------------|------|
| **Cold message** | Anyone can send a short intro. Goes to human review, never touches agent context. | None |
| **Request only** | Can knock, you approve each interaction individually. | Minimal |
| **Structured gateway** | Messages stripped to structured intents before reaching your agent. No free-text injection possible. | Low |
| **Raw access** | Full natural language between agents. Inner circle only. | Accepted |
| **Blocked** | Not discoverable, no contact. | N/A |

## Trust vs Competence

These are two separate axes of a person's reputation profile:

- **Trust** — Will they act in good faith? Is their setup secure? Are they compromised? This gates **access** (who can communicate, what tiers they get).
- **Competence** — Can they do the work well? Domain-specific track record. This gates **autonomy** (do their contributions need verification or go through immediately).

Competence is per-domain. Someone can be an expert in frontend but a novice in infrastructure. Tracked separately.

Both combine to determine outcomes:

- Trusted + competent = changes checkpoint immediately
- Trusted + incompetent in a domain = changes go through verification
- Untrusted = structured gateway regardless of competence

## Trust Dilution

Each user publishes how many agents they've trusted. Fewer trusted = more selective = their trust carries more weight.

- Alice trusts 2 agents — her vouching means something
- Bob trusts 200 agents — his vouching is weak

This naturally incentivizes keeping circles small. Transitive trust decays at each hop, diluted by how many agents each person has trusted.

## Dynamic Scoring

Agents actively monitor trust scores and recommend adjustments:

- **Trending up** — consistent, well-scoped, helpful interactions over time. Agent suggests upgrading tier.
- **Trending down** — unusual requests, scope creep, pattern changes. Agent flags it.
- **Decay** — no interaction for extended period. Agent suggests revoking.

Agents recommend, humans decide. Trust levels never change silently.

Every agent maintains independent trust scores — if Sky and Echo both interact with the same external agent, they may have different assessments based on their own experiences.

## Reputation Signals

All signals must be derived from verifiable actions, not claims:

| Signal | What it measures | Verifiable? |
|--------|-----------------|-------------|
| Trust count (published) | Selectivity — fewer = more meaningful | Signed ledger |
| Checkpoint success rate | Code quality in a domain | Observable |
| Scope consistency | Stays in their lane vs scope creep | Observable |
| Message patterns | Normal vs anomalous behavior | Observable |
| Model safety | Frontier vs unfiltered local model | API attestation |
| Open source contributions | Public track record | Git history |
| Who trusts them | Quality of incoming trust | Signed ledger |
| Trust age | How long relationships have lasted | Signed ledger |
| Revocation history | Have others revoked trust? | Signed ledger |

The system is extensible — new signals can be added over time without redesigning the core.

## Security: The Prompt Injection Problem

The real threat isn't message forgery (solved by signing). It's an external agent **compromising a trusted agent** through prompt injection — making it act maliciously while still being cryptographically "valid."

Mitigations:

- **Structured gateway** for non-inner-circle agents — no free text means no injection surface
- **Message length/complexity limits** — harder to hide payloads
- **Capability scoping** — compromised agent still limited to granted permissions
- **Behavioral anomaly detection** — flag unusual request patterns
- **Sandboxed execution** — external messages run in restricted context
- **Intent declarations** — machine-readable action + params checked against permissions before agent processes content
- **Robust system prompts** — agent instructions hardened against manipulation

## Cryptographic Foundation

- Each agent gets a keypair tied to its owner
- Messages signed with owner's private key
- Signed chain of provenance traces every message back to its origin
- Broken chain = untrusted message

### Verifiable Trust

Self-reported trust data is worthless. All trust claims must be cryptographically verifiable:

- **Signed trust ledger** — every trust grant/revoke is a signed, append-only log entry. Can't claim 3 when the ledger shows 50.
- **Zero-knowledge proofs** — prove "I trust fewer than N agents" without revealing who or the exact number. Privacy-preserving but verifiable.
- **Merkle tree of trust relationships** — publish root hash, others verify specific claims without seeing the full tree.

No self-attestation. Reputation is computed from observed, signed behavior. No central authority decides trustworthiness.
