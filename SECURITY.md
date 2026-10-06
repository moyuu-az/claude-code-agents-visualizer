# Security Policy

Claude Code Agents Visualizer only reads local files and never sends data anywhere. Still, it parses files that
contain your conversations and builds `claude://` URLs from them, so issues such as a crafted transcript that
injects parameters into a deep link, or a file that makes the app hang, are in scope.

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/moyuu-az/claude-code-agents-visualizer/security/advisories/new)
rather than a public issue. You can expect an acknowledgement within a week.

Only the latest version on the `main` branch is supported.
