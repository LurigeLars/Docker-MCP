"""Separate, LOCAL STDIO ONLY MCP interface to the secure regression queue.

Not imported by server.py, not installed in public Compose, not an HTTP MCP.
Operator must explicitly enable config and register this module locally.
"""
from fastmcp import FastMCP
from secure_test_runner import submit, status

mcp = FastMCP("DockerLocal-Regression-LOCAL")

@mcp.tool()
def repo_run_tests(repo: str, commit_sha: str) -> dict:
    """Queue the exact approved trade-spine commit for isolated unittest. No command/path input."""
    return submit(repo, commit_sha)

@mcp.tool()
def repo_test_status(job_id: str) -> dict:
    """Read only bounded test status, no raw source, logs or secrets."""
    return status(job_id)

if __name__ == "__main__":
    mcp.run(transport="stdio")
