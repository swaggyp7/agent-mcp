# agent-mcp for Windows

Windows launchers for [uukelele/agent-mcp](https://github.com/uukelele/agent-mcp), with an audit logging patch. The patch was generated against upstream commit 543ed13e9e78c70298b89a8072d1be8fbe87b01d.

1. Install PowerShell 7 and run **init.bat** from the cloned repository. It prepares the local tools and Python environment, clones upstream, and applies the patch.
2. Run **run.bat** to start MCP on port 8765. The launcher prints the address and the path to the local authentication token.
3. To customize the workspace, port, public URL, or allowed hosts, set the corresponding variables in **run.bat** or in your environment before launch.

Runtime credentials, audit logs, dependencies, and workspace contents are generated locally and excluded from Git.
