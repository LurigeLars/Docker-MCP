[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA "DockerLocalMCP\openai-egress-sync.local.json")
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$FeedUrl = "https://openai.com/chatgpt-connectors.json"
$ListName = "openai_chatgpt_egress"

function Write-State {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Data
    )

    $Data.timestampUtc = [DateTime]::UtcNow.ToString("o")
    $Data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-PlaintextSecret {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Cloudflare token secret is missing: $Path"
    }

    $Protected = (Get-Content -LiteralPath $Path -Raw).Trim()
    if (-not $Protected) {
        throw "Cloudflare token secret is empty: $Path"
    }

    $Secure = ConvertTo-SecureString $Protected
    return (New-Object System.Net.NetworkCredential("", $Secure)).Password
}

function Normalize-Prefix {
    param([Parameter(Mandatory = $true)][string]$Value)

    $Text = $Value.Trim()
    if (-not $Text) { throw "Encountered an empty IP prefix." }

    $AddressText = $Text
    $HasPrefix = $false
    $PrefixLength = 0
    if ($Text.Contains("/")) {
        $Parts = $Text.Split("/")
        $HasPrefix = $true
        if ($Parts.Count -ne 2 -or -not [int]::TryParse($Parts[1], [ref]$PrefixLength)) {
            throw "Invalid CIDR prefix: $Text"
        }
        $AddressText = $Parts[0]
    }

    $Address = $null
    if (-not [System.Net.IPAddress]::TryParse($AddressText, [ref]$Address)) {
        throw "Invalid IP address: $Text"
    }

    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        if (-not $HasPrefix) { $PrefixLength = 32 }
        if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) { throw "Invalid IPv4 prefix length: $Text" }
    }
    elseif ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if (-not $HasPrefix) { $PrefixLength = 128 }
        if ($PrefixLength -lt 0 -or $PrefixLength -gt 128) { throw "Invalid IPv6 prefix length: $Text" }
    }
    else {
        throw "Unsupported address family: $Text"
    }

    return "$($Address.ToString())/$PrefixLength"
}

function Invoke-Cloudflare {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST", "PUT")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Token,
        [object]$Body
    )

    $Uri = "https://api.cloudflare.com/client/v4$Path"
    $Headers = @{ Authorization = "Bearer $Token" }
    $Args = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ErrorAction = "Stop"
    }

    if ($PSBoundParameters.ContainsKey("Body")) {
        $Args.ContentType = "application/json"
        $Args.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }

    $Response = Invoke-RestMethod @Args
    if (-not $Response.success) {
        $Messages = @($Response.errors | ForEach-Object { "[$($_.code)] $($_.message)" }) -join "; "
        throw "Cloudflare API request failed: $Messages"
    }
    return $Response
}

function Get-CloudflareListItems {
    param(
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$ListId,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $Items = New-Object System.Collections.Generic.List[string]
    $Cursor = $null

    do {
        $Path = "/accounts/$AccountId/rules/lists/$ListId/items"
        if ($Cursor) {
            $Encoded = [Uri]::EscapeDataString($Cursor)
            $Path = "{0}?cursor={1}" -f $Path, $Encoded
        }

        $Response = Invoke-Cloudflare -Method GET -Path $Path -Token $Token
        foreach ($Item in @($Response.result)) {
            if (-not $Item.ip) { throw "Cloudflare returned a non-IP item in the IP list." }
            [void]$Items.Add((Normalize-Prefix -Value ([string]$Item.ip)))
        }

        $Cursor = $null
        $ResultInfoProperty = $Response.PSObject.Properties["result_info"]
        if ($ResultInfoProperty -and $ResultInfoProperty.Value) {
            $CursorsProperty = $ResultInfoProperty.Value.PSObject.Properties["cursors"]
            if ($CursorsProperty -and $CursorsProperty.Value) {
                $AfterProperty = $CursorsProperty.Value.PSObject.Properties["after"]
                if ($AfterProperty -and $AfterProperty.Value) {
                    $Cursor = [string]$AfterProperty.Value
                }
            }
        }
    } while ($Cursor)

    return @($Items)
}

function Test-ExactSet {
    param(
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string[]]$Actual
    )

    $ExpectedUnique = @($Expected | Sort-Object -Unique)
    $ActualUnique = @($Actual | Sort-Object -Unique)
    if ($ExpectedUnique.Count -ne $ActualUnique.Count) { return $false }
    return -not (Compare-Object -ReferenceObject $ExpectedUnique -DifferenceObject $ActualUnique)
}

$Root = Split-Path -Parent $ConfigPath
$StatePath = Join-Path $Root "openai-egress-sync-state.json"
$Token = $null

try {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Sync config is missing: $ConfigPath"
    }

    $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    foreach ($Required in @("accountId", "secretPath")) {
        if (-not $Config.$Required) { throw "Sync config is missing '$Required'." }
    }

    $Token = Get-PlaintextSecret -Path ([string]$Config.secretPath)

    $Feed = Invoke-RestMethod -Method GET -Uri $FeedUrl -ErrorAction Stop
    if (-not $Feed.creationTime) { throw "OpenAI feed is missing creationTime. Refusing to change Cloudflare." }
    if (-not $Feed.prefixes -or @($Feed.prefixes).Count -eq 0) {
        throw "OpenAI feed returned no prefixes. Refusing to change Cloudflare."
    }

    $Desired = New-Object System.Collections.Generic.List[string]
    foreach ($Entry in @($Feed.prefixes)) {
        $RawPrefix = $null
        $PropertyNames = @($Entry.PSObject.Properties.Name)
        if ($PropertyNames -contains "ipv4Prefix") { $RawPrefix = [string]$Entry.ipv4Prefix }
        elseif ($PropertyNames -contains "ipv6Prefix") { $RawPrefix = [string]$Entry.ipv6Prefix }
        else { throw "OpenAI feed contains a prefix entry without ipv4Prefix or ipv6Prefix." }
        [void]$Desired.Add((Normalize-Prefix -Value $RawPrefix))
    }

    $DesiredSet = @($Desired | Sort-Object -Unique)
    if ($DesiredSet.Count -ne $Desired.Count) {
        throw "OpenAI feed contains duplicate prefixes. Refusing to change Cloudflare."
    }

    $Lists = Invoke-Cloudflare -Method GET -Path "/accounts/$($Config.accountId)/rules/lists" -Token $Token
    $Matches = @($Lists.result | Where-Object { $_.name -eq $ListName })
    if ($Matches.Count -ne 1) {
        throw "Expected exactly one Cloudflare list named '$ListName'; found $($Matches.Count). Refusing to create or guess."
    }

    $List = $Matches[0]
    if ($List.kind -ne "ip") { throw "Cloudflare list '$ListName' is not an IP list." }

    $Current = @(Get-CloudflareListItems -AccountId ([string]$Config.accountId) -ListId ([string]$List.id) -Token $Token)
    if (Test-ExactSet -Expected $DesiredSet -Actual $Current) {
        Write-State -Path $StatePath -Data @{
            status           = "ok"
            changed          = $false
            feedCreationTime = [string]$Feed.creationTime
            prefixCount      = $DesiredSet.Count
            listId           = [string]$List.id
        }
        Write-Host "OpenAI egress list already matches Cloudflare ($($DesiredSet.Count) prefixes)."
        return
    }

    $Payload = @($DesiredSet | ForEach-Object { @{ ip = $_ } })
    $Update = Invoke-Cloudflare -Method PUT -Path "/accounts/$($Config.accountId)/rules/lists/$($List.id)/items" -Token $Token -Body $Payload
    $OperationId = [string]$Update.result.operation_id
    if (-not $OperationId) { throw "Cloudflare did not return a bulk operation ID." }

    $Deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 1
        $Operation = Invoke-Cloudflare -Method GET -Path "/accounts/$($Config.accountId)/rules/lists/bulk_operations/$OperationId" -Token $Token
        $Status = [string]$Operation.result.status
        if ($Status -eq "completed") { break }
        if ($Status -eq "failed") { throw "Cloudflare bulk update failed: $($Operation.result.error)" }
    } while ((Get-Date) -lt $Deadline)

    if ($Status -ne "completed") { throw "Timed out waiting for Cloudflare bulk update to complete." }

    $Verified = @(Get-CloudflareListItems -AccountId ([string]$Config.accountId) -ListId ([string]$List.id) -Token $Token)
    if (-not (Test-ExactSet -Expected $DesiredSet -Actual $Verified)) {
        throw "Post-update verification failed: Cloudflare list does not exactly match the OpenAI feed."
    }

    Write-State -Path $StatePath -Data @{
        status           = "ok"
        changed          = $true
        feedCreationTime = [string]$Feed.creationTime
        prefixCount      = $DesiredSet.Count
        listId           = [string]$List.id
    }
    Write-Host "Updated Cloudflare OpenAI egress list to $($DesiredSet.Count) prefixes and verified the result."
}
catch {
    try {
        Write-State -Path $StatePath -Data @{
            status  = "error"
            changed = $false
            error   = $_.Exception.Message
        }
    } catch {}
    throw
}
finally {
    if ($Token) { $Token = $null }
}
