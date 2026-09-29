# OpenAI ChatGPT egress sync

This optional Windows task keeps one existing Cloudflare account IP List synchronized with OpenAI's official ChatGPT integration egress feed:

https://openai.com/chatgpt-connectors.json

It is intentionally narrow:

- it only reads the OpenAI feed;
- it only reads and replaces items in one existing Cloudflare IP List;
- it never creates a missing list;
- it does not modify WAF rules, Access, DNS, tunnels, SSL/TLS, OAuth, or rate limits;
- it writes only when the normalized IP/CIDR set changed;
- it waits for Cloudflare's asynchronous list update and verifies an exact set match afterwards.

## Cloudflare token

Create a dedicated API token with only the account permission needed to maintain account IP Lists: **Account Filter Lists — Edit**. Scope it to the intended Cloudflare account. Do not reuse a broad administrative token.

The token is entered locally into the installer prompt. Do not pass it in chat or commit it to Git. The installer protects it with Windows DPAPI (CurrentUser) and stores the protected blob under %LOCALAPPDATA%\DockerLocalMCP.

## Install

From the repository checkout:

~~~powershell
.\install-openai-egress-sync.ps1 -AccountId '<32-character Cloudflare account id>'
~~~

The default list name is openai_chatgpt_egress and the default schedule is daily at 08:00. Both can be overridden:

~~~powershell
.\install-openai-egress-sync.ps1 -AccountId '<account id>' -ListName 'openai_chatgpt_egress' -At '08:00'
~~~

The installer performs one immediate verification/sync before it registers the scheduled task. The task runs as the current Windows user with RunLevel Limited, is hidden, and uses StartWhenAvailable.

Runtime state is written to:

%LOCALAPPDATA%\DockerLocalMCP\openai-egress-sync-state.json
