# AGENTS.md — Hydration NTT deployments

## Terminal, session and conversation privacy

- Never inspect the user's personal terminal sessions, scrollback, or shell history.
- Never read `~/.zsh_history`, `~/.bash_history`, or equivalent shell history files.
- Never inspect unrelated live processes, terminal sessions, or their output.
- Previous AI agent conversations and session histories may be consulted when relevant to the current task.
- Only access previous conversations to recover useful project context, architectural decisions, debugging findings, or implementation history.
- Do not indiscriminately scan unrelated conversations or session files.
- Prefer current repository documentation and source code over potentially outdated conversation context.
- Never expose credentials, private keys, or secrets discovered in previous sessions.
- Only use terminal output generated for the current task or explicitly provided by the user.
- These are behavioral instructions, not OS-level security restrictions.
