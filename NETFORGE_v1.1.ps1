# ============================================================
# NETFORGE v1.1
# Windows Network Toolkit
# PowerShell + Windows Forms
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
# ADMINISTRATOR CHECK
# ============================================================

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)

if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    [System.Windows.Forms.MessageBox]::Show(
        "NETFORGE must be run as Administrator.`n`nPlease use Start-NetForge.cmd.",
        "NETFORGE",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    exit
}

# ============================================================
# GLOBAL VARIABLES
# ============================================================

$script:ReportData = @()
$script:StopScan = $false
$script:ScanRunning = $false
$script:ScanRunspacePool = $null
$script:ScanJobs = @()

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Add-Output {
    param([string]$Text)

    if ($null -ne $txtOutput) {
        $txtOutput.AppendText("$Text`r`n")
        $txtOutput.SelectionStart = $txtOutput.Text.Length
        $txtOutput.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Add-Report {
    param(
        [string]$Category,
        [string]$Test,
        [string]$Status,
        [string]$Details
    )

    $script:ReportData += [PSCustomObject]@{
        Category = $Category
        Test     = $Test
        Status   = $Status
        Details  = $Details
    }
}

function Get-SelectedAdapterName {

    if ($null -eq $cmbAdapter.SelectedItem) {
        return $null
    }

    return $cmbAdapter.SelectedItem.ToString()
}

function Show-Confirm {
    param(
        [string]$Message
    )

    return [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "NETFORGE - Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
}

# ============================================================
# LOAD NETWORK ADAPTERS
# ============================================================

function Load-NetworkAdapters {

    $cmbAdapter.Items.Clear()

    try {

        $adapters = Get-NetAdapter |
            Where-Object {
                $_.Status -eq "Up" -or
                $_.Status -eq "Disconnected"
            } |
            Sort-Object InterfaceIndex

        foreach ($adapter in $adapters) {

            $cmbAdapter.Items.Add(
                $adapter.Name
            ) | Out-Null
        }

        if ($cmbAdapter.Items.Count -gt 0) {
            $cmbAdapter.SelectedIndex = 0
        }

        Add-Output "[+] Network adapters loaded."

    }
    catch {

        Add-Output "[!] Failed to load network adapters."
        Add-Output $_.Exception.Message
    }
}

# ============================================================
# NETWORK INFORMATION
# ============================================================

function Get-NetworkInformation {

    $adapterName = Get-SelectedAdapterName

    if (-not $adapterName) {
        Add-Output "[!] Please select a network adapter."
        return
    }

    try {

        $adapter = Get-NetAdapter `
            -Name $adapterName `
            -ErrorAction Stop

        $config = Get-NetIPConfiguration `
            -InterfaceIndex $adapter.ifIndex `
            -ErrorAction Stop

        $txtOutput.Clear()

        Add-Output "========================================"
        Add-Output " NETWORK INFORMATION"
        Add-Output "========================================"
        Add-Output ""

        Add-Output "Adapter       : $($adapter.Name)"
        Add-Output "Status        : $($adapter.Status)"
        Add-Output "Description   : $($adapter.InterfaceDescription)"
        Add-Output "MAC Address   : $($adapter.MacAddress)"
        Add-Output ""

        if ($config.IPv4Address) {
            Add-Output "IPv4 Address  : $($config.IPv4Address.IPAddress)"
            Add-Output "Prefix Length  : /$($config.IPv4Address.PrefixLength)"
        }
        else {
            Add-Output "IPv4 Address  : Not configured"
        }

        if ($config.IPv4DefaultGateway) {
            Add-Output "Gateway       : $($config.IPv4DefaultGateway.NextHop)"
        }
        else {
            Add-Output "Gateway       : Not configured"
        }

        if ($config.DnsServer.ServerAddresses) {
            Add-Output "DNS Servers   : $(
                $config.DnsServer.ServerAddresses -join ', '
            )"
        }
        else {
            Add-Output "DNS Servers   : Not configured"
        }

        $interface = Get-NetIPInterface `
            -InterfaceIndex $adapter.ifIndex `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue

        if ($interface) {
            Add-Output "DHCP          : $($interface.Dhcp)"
        }

        Add-Output ""

        Add-Report `
            "Network" `
            "Network Information" `
            "INFO" `
            "Adapter: $adapterName"

    }
    catch {

        Add-Output "[!] Unable to read network information."
        Add-Output $_.Exception.Message
    }
}

# ============================================================
# IPv4 VALIDATION
# ============================================================

function Test-ValidIPv4 {
    param(
        [string]$IPAddress
    )

    $parsed = $null

    $isValid = [System.Net.IPAddress]::TryParse(
        $IPAddress,
        [ref]$parsed
    )

    if (-not $isValid) {
        return $false
    }

    return (
        $parsed.AddressFamily -eq
        [System.Net.Sockets.AddressFamily]::InterNetwork
    )
}

# ============================================================
# APPLY DHCP
# ============================================================

function Set-IPv4DHCP {

    $adapterName = Get-SelectedAdapterName

    if (-not $adapterName) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please select a network adapter.",
            "NETFORGE"
        )
        return
    }

    $answer = Show-Confirm `
        "Restore DHCP / Automatic IPv4 and DNS on '$adapterName'?"

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {

        Add-Output ""
        Add-Output "[*] Restoring DHCP..."

        Set-NetIPInterface `
            -InterfaceAlias $adapterName `
            -AddressFamily IPv4 `
            -Dhcp Enabled `
            -ErrorAction Stop

        Get-NetIPAddress `
            -InterfaceAlias $adapterName `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PrefixOrigin -eq "Manual"
            } |
            Remove-NetIPAddress `
                -Confirm:$false `
                -ErrorAction SilentlyContinue

        Set-DnsClientServerAddress `
            -InterfaceAlias $adapterName `
            -ResetServerAddresses `
            -ErrorAction Stop

        Add-Output "[+] DHCP enabled."
        Add-Output "[+] DNS restored to automatic."

        Add-Report `
            "IPv4 Configuration" `
            "Restore DHCP" `
            "PASS" `
            "DHCP and automatic DNS restored."

    }
    catch {

        Add-Output "[!] DHCP configuration failed."
        Add-Output $_.Exception.Message

        Add-Report `
            "IPv4 Configuration" `
            "Restore DHCP" `
            "FAIL" `
            $_.Exception.Message
    }
}

# ============================================================
# APPLY STATIC IPv4
# ============================================================

function Set-StaticIPv4 {

    $adapterName = Get-SelectedAdapterName

    if (-not $adapterName) {
        [System.Windows.Forms.MessageBox]::Show(
            "Please select a network adapter.",
            "NETFORGE"
        )
        return
    }

    $ip = $txtIPv4.Text.Trim()
    $prefix = $txtPrefix.Text.Trim()
    $gateway = $txtGateway.Text.Trim()
    $dns1 = $txtDNS1.Text.Trim()
    $dns2 = $txtDNS2.Text.Trim()

    # -----------------------------
    # Validate IP
    # -----------------------------

    if (-not (Test-ValidIPv4 $ip)) {

        [System.Windows.Forms.MessageBox]::Show(
            "Invalid IPv4 address.",
            "NETFORGE - Validation"
        )

        return
    }

    # -----------------------------
    # Validate Prefix
    # -----------------------------

    $prefixNumber = 0

    if (
        -not [int]::TryParse(
            $prefix,
            [ref]$prefixNumber
        )
    ) {

        [System.Windows.Forms.MessageBox]::Show(
            "Subnet Prefix must be a number between 1 and 32.",
            "NETFORGE - Validation"
        )

        return
    }

    if ($prefixNumber -lt 1 -or $prefixNumber -gt 32) {

        [System.Windows.Forms.MessageBox]::Show(
            "Subnet Prefix must be between 1 and 32.",
            "NETFORGE - Validation"
        )

        return
    }

    # -----------------------------
    # Validate Gateway
    # -----------------------------

    if ($gateway -and -not (Test-ValidIPv4 $gateway)) {

        [System.Windows.Forms.MessageBox]::Show(
            "Invalid Gateway address.",
            "NETFORGE - Validation"
        )

        return
    }

    # -----------------------------
    # Validate DNS
    # -----------------------------

    if ($dns1 -and -not (Test-ValidIPv4 $dns1)) {

        [System.Windows.Forms.MessageBox]::Show(
            "Invalid Preferred DNS address.",
            "NETFORGE - Validation"
        )

        return
    }

    if ($dns2 -and -not (Test-ValidIPv4 $dns2)) {

        [System.Windows.Forms.MessageBox]::Show(
            "Invalid Alternate DNS address.",
            "NETFORGE - Validation"
        )

        return
    }

    # -----------------------------
    # Confirmation
    # -----------------------------

    $summary = @"
Adapter : $adapterName

IPv4    : $ip
Prefix  : /$prefixNumber
Gateway : $gateway
DNS 1   : $dns1
DNS 2   : $dns2

Applying this configuration may temporarily
disconnect the network.

Continue?
"@

    $answer = Show-Confirm $summary

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {

        Add-Output ""
        Add-Output "========================================"
        Add-Output " APPLYING IPv4 CONFIGURATION"
        Add-Output "========================================"
        Add-Output ""

        Add-Output "[*] Adapter: $adapterName"
        Add-Output "[*] IPv4: $ip/$prefixNumber"

        # Enable manual IPv4
        Set-NetIPInterface `
            -InterfaceAlias $adapterName `
            -AddressFamily IPv4 `
            -Dhcp Disabled `
            -ErrorAction Stop

        # Remove existing manual IPv4 addresses
        Get-NetIPAddress `
            -InterfaceAlias $adapterName `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PrefixOrigin -eq "Manual" -and
                $_.IPAddress -ne "127.0.0.1"
            } |
            Remove-NetIPAddress `
                -Confirm:$false `
                -ErrorAction SilentlyContinue

        # Remove existing IPv4 default routes first.
        # This prevents:
        # "Instance DefaultGateway already exists"
        Get-NetRoute `
            -InterfaceAlias $adapterName `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DestinationPrefix -eq "0.0.0.0/0"
            } |
            Remove-NetRoute `
                -Confirm:$false `
                -ErrorAction SilentlyContinue

        # Create the new IPv4 address WITHOUT a gateway.
        # The gateway is added separately below.
        New-NetIPAddress `
            -InterfaceAlias $adapterName `
            -IPAddress $ip `
            -PrefixLength $prefixNumber `
            -ErrorAction Stop | Out-Null

        # Add the default gateway separately.
        if ($gateway) {

            New-NetRoute `
                -InterfaceAlias $adapterName `
                -AddressFamily IPv4 `
                -DestinationPrefix "0.0.0.0/0" `
                -NextHop $gateway `
                -ErrorAction Stop | Out-Null
        }

        # DNS
        $dnsServers = @()

        if ($dns1) {
            $dnsServers += $dns1
        }

        if ($dns2) {
            $dnsServers += $dns2
        }

        if ($dnsServers.Count -gt 0) {

            Set-DnsClientServerAddress `
                -InterfaceAlias $adapterName `
                -ServerAddresses $dnsServers `
                -ErrorAction Stop
        }

        Add-Output "[+] IPv4 configuration applied."

        if ($dnsServers.Count -gt 0) {
            Add-Output "[+] DNS configuration applied."
        }

        Add-Report `
            "IPv4 Configuration" `
            "Static IPv4 Configuration" `
            "PASS" `
            "IP=$ip/$prefixNumber Gateway=$gateway DNS=$($dnsServers -join ', ')"

        [System.Windows.Forms.MessageBox]::Show(
            "IPv4 configuration applied successfully.",
            "NETFORGE",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )

        Get-NetworkInformation

    }
    catch {

        Add-Output "[!] IPv4 configuration failed."
        Add-Output $_.Exception.Message

        Add-Report `
            "IPv4 Configuration" `
            "Static IPv4 Configuration" `
            "FAIL" `
            $_.Exception.Message

        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "NETFORGE - Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

# ============================================================
# GATEWAY TEST
# ============================================================

function Test-Gateway {

    $adapterName = Get-SelectedAdapterName

    if (-not $adapterName) {
        Add-Output "[!] Select an adapter first."
        return
    }

    try {

        $config = Get-NetIPConfiguration `
            -InterfaceAlias $adapterName `
            -ErrorAction Stop

        if (-not $config.IPv4DefaultGateway) {

            Add-Output "[!] No IPv4 default gateway found."

            Add-Report `
                "Connectivity" `
                "Gateway Test" `
                "FAIL" `
                "No default gateway configured."

            return
        }

        $gateway = $config.IPv4DefaultGateway.NextHop

        Add-Output ""
        Add-Output "[*] Testing gateway: $gateway"

        $result = Test-Connection `
            -ComputerName $gateway `
            -Count 2 `
            -Quiet `
            -ErrorAction SilentlyContinue

        if ($result) {

            Add-Output "[+] Gateway: ONLINE"

            Add-Report `
                "Connectivity" `
                "Gateway Test" `
                "PASS" `
                "$gateway is reachable."
        }
        else {

            Add-Output "[!] Gateway: UNREACHABLE"

            Add-Report `
                "Connectivity" `
                "Gateway Test" `
                "FAIL" `
                "$gateway is unreachable."
        }

    }
    catch {

        Add-Output "[!] Gateway test failed."
        Add-Output $_.Exception.Message
    }
}

# ============================================================
# DNS TEST
# ============================================================

function Test-DNS {

    Add-Output ""
    Add-Output "[*] Testing DNS resolution..."

    try {

        Resolve-DnsName `
            "microsoft.com" `
            -ErrorAction Stop | Out-Null

        Add-Output "[+] DNS resolution: WORKING"

        Add-Report `
            "DNS" `
            "DNS Resolution" `
            "PASS" `
            "microsoft.com resolved successfully."
    }
    catch {

        Add-Output "[!] DNS resolution: FAILED"

        Add-Report `
            "DNS" `
            "DNS Resolution" `
            "FAIL" `
            $_.Exception.Message
    }
}

# ============================================================
# INTERNET TEST
# ============================================================

function Test-Internet {

    Add-Output ""
    Add-Output "[*] Testing internet connectivity..."

    try {

        $result = Test-Connection `
            -ComputerName "8.8.8.8" `
            -Count 2 `
            -Quiet `
            -ErrorAction Stop

        if ($result) {

            Add-Output "[+] Internet: ONLINE"

            Add-Report `
                "Connectivity" `
                "Internet Connectivity" `
                "PASS" `
                "8.8.8.8 is reachable."
        }
        else {

            Add-Output "[!] Internet: OFFLINE"

            Add-Report `
                "Connectivity" `
                "Internet Connectivity" `
                "FAIL" `
                "8.8.8.8 is unreachable."
        }
    }
    catch {

        Add-Output "[!] Internet test failed."

        Add-Report `
            "Connectivity" `
            "Internet Connectivity" `
            "FAIL" `
            $_.Exception.Message
    }
}

# ============================================================
# LATENCY TEST
# ============================================================

function Test-Latency {

    Add-Output ""
    Add-Output "[*] Running latency test..."

    try {

        $results = Test-Connection `
            -ComputerName "8.8.8.8" `
            -Count 4 `
            -ErrorAction Stop

        $times = $results |
            Select-Object -ExpandProperty ResponseTime

        $average = [math]::Round(
            ($times | Measure-Object -Average).Average,
            2
        )

        Add-Output "[+] Average latency: $average ms"

        Add-Report `
            "Performance" `
            "Latency Test" `
            "PASS" `
            "Average latency: $average ms"
    }
    catch {

        Add-Output "[!] Latency test failed."

        Add-Report `
            "Performance" `
            "Latency Test" `
            "FAIL" `
            $_.Exception.Message
    }
}

# ============================================================
# FLUSH DNS
# ============================================================

function Clear-DNSCache {

    Add-Output ""
    Add-Output "[*] Flushing DNS cache..."

    try {

        Clear-DnsClientCache

        Add-Output "[+] DNS cache flushed."

        Add-Report `
            "Repair" `
            "Flush DNS Cache" `
            "PASS" `
            "DNS client cache cleared."
    }
    catch {

        Add-Output "[!] DNS flush failed."
        Add-Output $_.Exception.Message
    }
}

# ============================================================
# RENEW IP
# ============================================================

function Renew-IP {

    $adapterName = Get-SelectedAdapterName

    if (-not $adapterName) {
        Add-Output "[!] Select an adapter first."
        return
    }

    Add-Output ""
    Add-Output "[*] Renewing IP address..."

    try {

        ipconfig /renew $adapterName |
            ForEach-Object {
                Add-Output $_
            }

        Add-Output "[+] IP renewal completed."

        Add-Report `
            "Repair" `
            "Renew IP" `
            "PASS" `
            "DHCP renewal requested."
    }
    catch {

        Add-Output "[!] IP renewal failed."
        Add-Output $_.Exception.Message
    }
}

# ============================================================
# WINSOCK RESET
# ============================================================

function Reset-Winsock {

    $answer = Show-Confirm `
        "Winsock reset may require a Windows restart.`n`nContinue?"

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    Add-Output ""
    Add-Output "[*] Resetting Winsock..."

    netsh winsock reset |
        ForEach-Object {
            Add-Output $_
        }

    Add-Output "[+] Winsock reset completed."
    Add-Output "[!] Restart may be required."

    Add-Report `
        "Repair" `
        "Winsock Reset" `
        "COMPLETED" `
        "Winsock reset performed."
}

# ============================================================
# TCP/IP RESET
# ============================================================

function Reset-TCPIP {

    $answer = Show-Confirm `
        "TCP/IP reset may affect network connectivity.`n`nContinue?"

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    Add-Output ""
    Add-Output "[*] Resetting TCP/IP stack..."

    netsh int ip reset |
        ForEach-Object {
            Add-Output $_
        }

    Add-Output "[+] TCP/IP reset completed."
    Add-Output "[!] Restart may be required."

    Add-Report `
        "Repair" `
        "TCP/IP Reset" `
        "COMPLETED" `
        "TCP/IP stack reset performed."
}

# ============================================================
# RESTART NETWORK ADAPTER
# ============================================================

function Restart-NetworkAdapter {

    $adapterName = Get-SelectedAdapterName

    if (-not $adapterName) {
        Add-Output "[!] Select an adapter first."
        return
    }

    $answer = Show-Confirm `
        "Restart network adapter '$adapterName'?"

    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {

        Add-Output ""
        Add-Output "[*] Restarting adapter..."

        Restart-NetAdapter `
            -Name $adapterName `
            -Confirm:$false

        Start-Sleep -Seconds 2

        Add-Output "[+] Adapter restarted."

        Add-Report `
            "Repair" `
            "Restart Adapter" `
            "COMPLETED" `
            "$adapterName restarted."
    }
    catch {

        Add-Output "[!] Adapter restart failed."
        Add-Output $_.Exception.Message
    }
}

# ============================================================
# IPv4 INTEGER CONVERSION
# ============================================================

function Convert-IPv4ToUInt32 {
    param([string]$IPAddress)

    $bytes = [System.Net.IPAddress]::Parse(
        $IPAddress
    ).GetAddressBytes()

    [Array]::Reverse($bytes)

    return [BitConverter]::ToUInt32(
        $bytes,
        0
    )
}

function Convert-UInt32ToIPv4 {
    param([uint32]$Value)

    $bytes = [BitConverter]::GetBytes($Value)

    [Array]::Reverse($bytes)

    return (
        [System.Net.IPAddress]::new($bytes)
    ).ToString()
}

# ============================================================
# CIDR RANGE
# ============================================================

function Get-NetworkRangeFromCIDR {

    param([string]$CIDR)

    if (
        $CIDR -notmatch
        '^(\d{1,3}(?:\.\d{1,3}){3})\/(\d{1,2})$'
    ) {
        throw "Invalid CIDR format."
    }

    $ip = $matches[1]
    $prefix = [int]$matches[2]

    if (-not (Test-ValidIPv4 $ip)) {
        throw "Invalid IPv4 address."
    }

    if ($prefix -lt 1 -or $prefix -gt 32) {
        throw "Prefix must be between /1 and /32."
    }

    $ipValue = Convert-IPv4ToUInt32 $ip

    if ($prefix -eq 0) {
        $mask = [uint32]0
    }
    elseif ($prefix -eq 32) {
        $mask = [uint32]0xFFFFFFFF
    }
    else {

        $mask = [uint32](
            ([uint64]0xFFFFFFFF) -shl (32 - $prefix)
        )
    }

    $network = $ipValue -band $mask

    $hostMask = [uint32](
        ([uint64]0xFFFFFFFF) -bxor $mask
    )

    $broadcast = $network -bor $hostMask

    if ($prefix -ge 31) {

        $start = $network
        $end = $broadcast

    }
    else {

        $start = $network + 1
        $end = $broadcast - 1
    }

    [PSCustomObject]@{
        Network   = Convert-UInt32ToIPv4 $network
        Broadcast = Convert-UInt32ToIPv4 $broadcast
        Start     = $start
        End       = $end
        Count     = [uint64]($end - $start + 1)
    }
}

# ============================================================
# MANUAL IP RANGE
# ============================================================

function Get-NetworkRangeFromDash {

    param([string]$Range)

    if (
        $Range -notmatch
        '^\s*(.+?)\s*-\s*(.+?)\s*$'
    ) {
        throw "Invalid IP range format."
    }

    $startIP = $matches[1].Trim()
    $endIP = $matches[2].Trim()

    if (-not (Test-ValidIPv4 $startIP)) {
        throw "Invalid start IPv4 address."
    }

    if (-not (Test-ValidIPv4 $endIP)) {
        throw "Invalid end IPv4 address."
    }

    $start = Convert-IPv4ToUInt32 $startIP
    $end = Convert-IPv4ToUInt32 $endIP

    if ($start -gt $end) {
        throw "Start IP cannot be greater than end IP."
    }

    [PSCustomObject]@{
        Network   = $startIP
        Broadcast = $endIP
        Start     = $start
        End       = $end
        Count     = [uint64]($end - $start + 1)
    }
}

# ============================================================
# NETWORK DISCOVERY
# ============================================================

function Start-NetworkScan {

    if ($script:ScanRunning) {
        return
    }

    $rangeText = $txtScanRange.Text.Trim()

    try {
        if ([string]::IsNullOrWhiteSpace($rangeText)) {

            $adapterName = Get-SelectedAdapterName

            if (-not $adapterName) {
                throw "Please select a network adapter."
            }

            $adapter = Get-NetAdapter -Name $adapterName -ErrorAction Stop
            $config = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction Stop
            $ipv4 = $config.IPv4Address | Select-Object -First 1

            if (-not $ipv4) {
                throw "No IPv4 address found."
            }

            $cidr = "$($ipv4.IPAddress)/$($ipv4.PrefixLength)"
            $range = Get-NetworkRangeFromCIDR $cidr

            $scanMode = "AUTO DETECT"
            $scanInfo = "Adapter: $adapterName | IPv4: $($ipv4.IPAddress)/$($ipv4.PrefixLength)"
        }
        elseif ($rangeText -match '/') {

            $range = Get-NetworkRangeFromCIDR $rangeText
            $scanMode = "MANUAL CIDR"
            $scanInfo = "CIDR: $rangeText"
        }
        elseif ($rangeText -match '-') {

            $range = Get-NetworkRangeFromDash $rangeText
            $scanMode = "MANUAL RANGE"
            $scanInfo = "Range: $rangeText"
        }
        else {
            throw "Invalid format."
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Invalid network range.`n`nUse:`n192.168.1.0/24`n192.168.1.1-192.168.1.100",
            "NETFORGE - Invalid Range",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    if ($range.Count -gt 4096) {
        [System.Windows.Forms.MessageBox]::Show(
            "The selected range contains $($range.Count) addresses.`n`nPlease select a smaller range.",
            "NETFORGE - Range Too Large",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $script:StopScan = $false
    $script:ScanRunning = $true
    $btnScan.Enabled = $false
    $btnStopScan.Enabled = $true
    $btnExit.Enabled = $true
    $cmbAdapter.Enabled = $false
    $txtScanRange.Enabled = $false

    $txtOutput.Clear()

    Add-Output "========================================"
    Add-Output " NETFORGE FAST NETWORK DISCOVERY"
    Add-Output "========================================"
    Add-Output ""
    Add-Output "Mode         : $scanMode"
    Add-Output "$scanInfo"
    Add-Output "Network      : $($range.Network)"
    Add-Output "End Address  : $($range.Broadcast)"
    Add-Output "Hosts        : $($range.Count)"
    Add-Output ""

    # Create IP list.
    $targets = New-Object System.Collections.Generic.List[string]

    for ([uint64]$current = $range.Start; $current -le $range.End; $current++) {
        $targets.Add((Convert-UInt32ToIPv4 ([uint32]$current)))
    }

    # Runspace pool keeps the UI responsive while several hosts are checked at once.
    $pool = [RunspaceFactory]::CreateRunspacePool(1, 32)
    $pool.Open()
    $script:ScanRunspacePool = $pool
    $script:ScanJobs = @()

    $worker = {
        param($Target)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ping = New-Object System.Net.NetworkInformation.Ping

        try {
            # 350 ms keeps offline hosts from making the scan unnecessarily slow.
            $reply = $ping.Send($Target, 350)

            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                [PSCustomObject]@{
                    IP          = $Target
                    Online      = $true
                    ResponseMs  = $reply.RoundtripTime
                }
            }
            else {
                [PSCustomObject]@{
                    IP          = $Target
                    Online      = $false
                    ResponseMs  = 0
                }
            }
        }
        catch {
            [PSCustomObject]@{
                IP          = $Target
                Online      = $false
                ResponseMs  = 0
            }
        }
        finally {
            $ping.Dispose()
            $sw.Stop()
        }
    }

    foreach ($target in $targets) {
        if ($script:StopScan) { break }

        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($worker).AddArgument($target)

        $handle = $ps.BeginInvoke()

        $script:ScanJobs += [PSCustomObject]@{
            IP     = $target
            PS     = $ps
            Handle = $handle
        }

        # Keep no more than 32 active requests at once.
        while (
            ($script:ScanJobs | Where-Object { -not $_.Handle.IsCompleted }).Count -ge 32
        ) {
            if ($script:StopScan) { break }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 10
        }

        if ($script:StopScan) { break }
    }

    $total = $script:ScanJobs.Count
    $processed = 0
    $online = 0
    $results = New-Object System.Collections.Generic.List[object]

    while (($processed -lt $total) -and (-not $script:StopScan)) {

        $completedJobs = @(
            $script:ScanJobs |
            Where-Object { $_.Handle.IsCompleted -and -not $_.PS.Tag }
        )

        foreach ($job in $completedJobs) {

            try {
                $result = $job.PS.EndInvoke($job.Handle)

                if ($result) {
                    $results.Add($result[0])

                    if ($result[0].Online) {
                        $online++

                        $hostname = "Unknown"

                        try {
                            $hostname = [System.Net.Dns]::GetHostEntry(
                                $result[0].IP
                            ).HostName
                        }
                        catch {}

                        Add-Output (
                            "[ONLINE]  {0,-16} {1,-35} {2} ms" -f
                            $result[0].IP,
                            $hostname,
                            $result[0].ResponseMs
                        )

                        Add-Report `
                            "Discovery" `
                            $result[0].IP `
                            "ONLINE" `
                            "Hostname: $hostname | Response: $($result[0].ResponseMs) ms"
                    }
                }
            }
            catch {}

            $job.PS.Tag = $true
            $processed++
            $job.PS.Dispose()
        }

        $lblScanStatus.Text =
            "Scanning $processed / $total | Online: $online"

        [System.Windows.Forms.Application]::DoEvents()

        if ($script:StopScan) {
            break
        }

        Start-Sleep -Milliseconds 20
    }

    # If STOP was pressed, cancel anything still running.
    if ($script:StopScan) {

        foreach ($job in $script:ScanJobs) {
            if (-not $job.PS.Tag) {
                try {
                    $job.PS.Stop()
                }
                catch {}

                try {
                    $job.PS.Dispose()
                }
                catch {}
            }
        }

        Add-Output ""
        Add-Output "[!] Scan stopped by user."
        Add-Output "Completed     : $processed / $total"
        Add-Output "Online found  : $online"

        $lblScanStatus.Text =
            "Stopped | $online online / $processed completed"
    }
    else {

        Add-Output ""
        Add-Output "========================================"
        Add-Output " SCAN COMPLETED"
        Add-Output "========================================"
        Add-Output ""
        Add-Output "Hosts Scanned : $total"
        Add-Output "Online        : $online"
        Add-Output "Offline       : $($total - $online)"

        $lblScanStatus.Text =
            "Completed | $online online / $total scanned"
    }

    try {
        $pool.Close()
        $pool.Dispose()
    }
    catch {}

    $script:ScanRunspacePool = $null
    $script:ScanJobs = @()
    $script:ScanRunning = $false
    $script:StopScan = $false

    $btnScan.Enabled = $true
    $btnStopScan.Enabled = $false
    $cmbAdapter.Enabled = $true
    $txtScanRange.Enabled = $true
}

function Stop-NetworkScan {

    if (-not $script:ScanRunning) {
        return
    }

    $script:StopScan = $true
    $lblScanStatus.Text = "Stopping scan..."

    Add-Output ""
    Add-Output "[*] Stop requested..."
}

# ============================================================
# FULL DIAGNOSIS
# ============================================================

function Run-FullDiagnosis {

    $txtOutput.Clear()

    Add-Output "========================================"
    Add-Output " NETFORGE FULL DIAGNOSIS"
    Add-Output "========================================"
    Add-Output ""

    Add-Output "[1/5] Network information..."
    Get-NetworkInformation

    Add-Output ""
    Add-Output "[2/5] Gateway test..."
    Test-Gateway

    Add-Output ""
    Add-Output "[3/5] DNS test..."
    Test-DNS

    Add-Output ""
    Add-Output "[4/5] Internet test..."
    Test-Internet

    Add-Output ""
    Add-Output "[5/5] Latency test..."
    Test-Latency

    Add-Output ""
    Add-Output "========================================"
    Add-Output " DIAGNOSIS COMPLETED"
    Add-Output "========================================"
}

# ============================================================
# HTML REPORT
# ============================================================

function Generate-HTMLReport {

    if ($script:ReportData.Count -eq 0) {

        [System.Windows.Forms.MessageBox]::Show(
            "Run at least one diagnostic first.",
            "NETFORGE"
        )

        return
    }

    $reportFolder =
        Join-Path $PSScriptRoot "reports"

    if (-not (Test-Path $reportFolder)) {

        New-Item `
            -ItemType Directory `
            -Path $reportFolder `
            -Force | Out-Null
    }

    $timestamp =
        Get-Date -Format "yyyyMMdd_HHmmss"

    $reportPath =
        Join-Path `
            $reportFolder `
            "NetForge_Report_$timestamp.html"

    $rows = ""

    foreach ($item in $script:ReportData) {

        $rows += @"
<tr>
<td>$($item.Category)</td>
<td>$($item.Test)</td>
<td>$($item.Status)</td>
<td>$($item.Details)</td>
</tr>
"@
    }

    $html = @"
<!DOCTYPE html>

<html>

<head>

<meta charset="UTF-8">

<title>NETFORGE Network Report</title>

<style>

body {
    font-family: Arial, sans-serif;
    background: #f4f6f8;
    margin: 40px;
}

.container {
    max-width: 1200px;
    margin: auto;
    background: white;
    padding: 30px;
    border-radius: 10px;
}

h1 {
    margin-bottom: 5px;
}

table {
    width: 100%;
    border-collapse: collapse;
    margin-top: 25px;
}

th,
td {
    border: 1px solid #ddd;
    padding: 10px;
    text-align: left;
}

th {
    background: #222;
    color: white;
}

.footer {
    margin-top: 30px;
    color: #666;
    font-size: 12px;
}

</style>

</head>

<body>

<div class="container">

<h1>NETFORGE</h1>

<h2>Windows Network Diagnostic Report</h2>

<p>
<b>Computer:</b>
$env:COMPUTERNAME
</p>

<p>
<b>User:</b>
$env:USERNAME
</p>

<p>
<b>Date:</b>
$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
</p>

<table>

<tr>

<th>Category</th>
<th>Test</th>
<th>Status</th>
<th>Details</th>

</tr>

$rows

</table>

<div class="footer">

Generated by NETFORGE Windows Network Toolkit.

</div>

</div>

</body>

</html>
"@

    $html |
        Out-File `
            -FilePath $reportPath `
            -Encoding UTF8

    Add-Output ""
    Add-Output "[+] HTML report created."
    Add-Output $reportPath

    Start-Process $reportPath
}

# ============================================================
# MAIN FORM
# ============================================================

$form = New-Object System.Windows.Forms.Form

$form.Text =
    "NETFORGE - Windows Network Toolkit"

$form.Size =
    New-Object System.Drawing.Size(1080,850)

$form.StartPosition =
    "CenterScreen"

$form.FormBorderStyle =
    "FixedSingle"

$form.MaximizeBox = $false

$form.BackColor = [System.Drawing.Color]::White

# ============================================================
# TITLE
# ============================================================

$lblTitle = New-Object System.Windows.Forms.Label

$lblTitle.Text = "NETFORGE"

$lblTitle.Font =
    New-Object System.Drawing.Font(
        "Consolas",
        20,
        [System.Drawing.FontStyle]::Bold
    )

$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(30,30,30)

$lblTitle.Location =
    New-Object System.Drawing.Point(25,15)

$lblTitle.AutoSize = $true

$form.Controls.Add($lblTitle)

$lblSubtitle = New-Object System.Windows.Forms.Label

$lblSubtitle.Text =
    "Windows Network Toolkit"

$lblSubtitle.Font =
    New-Object System.Drawing.Font(
        "Consolas",
        10
    )

$lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(100,100,100)

$lblSubtitle.Location =
    New-Object System.Drawing.Point(30,52)

$lblSubtitle.AutoSize = $true

$form.Controls.Add($lblSubtitle)

# ============================================================
# ADAPTER
# ============================================================

$lblAdapter = New-Object System.Windows.Forms.Label

$lblAdapter.Text =
    "Network Adapter:"

$lblAdapter.ForeColor =
    [System.Drawing.Color]::FromArgb(40,40,40)

$lblAdapter.Location =
    New-Object System.Drawing.Point(30,85)

$lblAdapter.AutoSize = $true

$form.Controls.Add($lblAdapter)

$cmbAdapter = New-Object System.Windows.Forms.ComboBox

$cmbAdapter.Location =
    New-Object System.Drawing.Point(150,82)

$cmbAdapter.Size =
    New-Object System.Drawing.Size(350,25)

$cmbAdapter.DropDownStyle =
    "DropDownList"

$form.Controls.Add($cmbAdapter)

# ============================================================
# BUTTON FUNCTION
# ============================================================

function New-ToolButton {

    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 145
    )

    $button =
        New-Object System.Windows.Forms.Button

    $button.Text = $Text

    $button.Location =
        New-Object System.Drawing.Point($X,$Y)

    $button.Size =
        New-Object System.Drawing.Size(
            $Width,
            38
        )

    $button.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
    $button.ForeColor = [System.Drawing.Color]::FromArgb(30,30,30)
    $button.FlatStyle = "Flat"
    $button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200,200,200)

    $form.Controls.Add($button)

    return $button
}

# ============================================================
# TOP BUTTONS
# ============================================================

$btnInfo =
    New-ToolButton "Network Info" 30 120 145

$btnGateway =
    New-ToolButton "Test Gateway" 185 120 145

$btnDNS =
    New-ToolButton "DNS Test" 340 120 145

$btnInternet =
    New-ToolButton "Internet Test" 495 120 145

$btnLatency =
    New-ToolButton "Latency Test" 650 120 145

$btnFull =
    New-ToolButton "FULL DIAGNOSIS" 805 120 180

# ============================================================
# REPAIR BUTTONS
# ============================================================

$btnFlush =
    New-ToolButton "Flush DNS" 30 165 145

$btnRenew =
    New-ToolButton "Renew IP" 185 165 145

$btnAdapterRestart =
    New-ToolButton "Restart Adapter" 340 165 145

$btnWinsock =
    New-ToolButton "Reset Winsock" 495 165 145

$btnTCP =
    New-ToolButton "Reset TCP/IP" 650 165 145

# ============================================================
# IPv4 CONFIGURATION PANEL
# ============================================================

$grpIPv4 =
    New-Object System.Windows.Forms.GroupBox

$grpIPv4.Text =
    "IPv4 Configuration"

$grpIPv4.ForeColor =
    [System.Drawing.Color]::FromArgb(40,40,40)

$grpIPv4.Location =
    New-Object System.Drawing.Point(30,215)

$grpIPv4.Size =
    New-Object System.Drawing.Size(475,190)

$form.Controls.Add($grpIPv4)

# -----------------------------
# IP
# -----------------------------

$lblIPv4 =
    New-Object System.Windows.Forms.Label

$lblIPv4.Text = "IPv4 Address:"

$lblIPv4.ForeColor =
    [System.Drawing.Color]::FromArgb(40,40,40)

$lblIPv4.Location =
    New-Object System.Drawing.Point(15,30)

$lblIPv4.AutoSize = $true

$grpIPv4.Controls.Add($lblIPv4)

$txtIPv4 =
    New-Object System.Windows.Forms.TextBox

$txtIPv4.Location =
    New-Object System.Drawing.Point(115,27)

$txtIPv4.Size =
    New-Object System.Drawing.Size(150,25)

$grpIPv4.Controls.Add($txtIPv4)

# -----------------------------
# Prefix
# -----------------------------

$lblPrefix =
    New-Object System.Windows.Forms.Label

$lblPrefix.Text = "Prefix:"

$lblPrefix.ForeColor =
    [System.Drawing.Color]::FromArgb(40,40,40)

$lblPrefix.Location =
    New-Object System.Drawing.Point(280,30)

$lblPrefix.AutoSize = $true

$grpIPv4.Controls.Add($lblPrefix)

$txtPrefix =
    New-Object System.Windows.Forms.TextBox

$txtPrefix.Location =
    New-Object System.Drawing.Point(330,27)

$txtPrefix.Size =
    New-Object System.Drawing.Size(100,25)

$txtPrefix.Text = "24"

$grpIPv4.Controls.Add($txtPrefix)

# -----------------------------
# Gateway
# -----------------------------

$lblGateway =
    New-Object System.Windows.Forms.Label

$lblGateway.Text = "Gateway:"

$lblGateway.ForeColor =
    [System.Drawing.Color]::FromArgb(40,40,40)

$lblGateway.Location =
    New-Object System.Drawing.Point(15,65)

$lblGateway.AutoSize = $true

$grpIPv4.Controls.Add($lblGateway)

$txtGateway =
    New-Object System.Windows.Forms.TextBox

$txtGateway.Location =
    New-Object System.Drawing.Point(115,62)

$txtGateway.Size =
    New-Object System.Drawing.Size(150,25)

$grpIPv4.Controls.Add($txtGateway)

# -----------------------------
# DNS 1
# -----------------------------

$lblDNS1 =
    New-Object System.Windows.Forms.Label

$lblDNS1.Text = "Preferred DNS:"

$lblDNS1.ForeColor =
    [System.Drawing.Color]::FromArgb(40,40,40)

$lblDNS1.Location =
    New-Object System.Drawing.Point(15,100)

$lblDNS1.AutoSize = $true

$grpIPv4.Controls.Add($lblDNS1)

$txtDNS1 =
    New-Object System.Windows.Forms.TextBox

$txtDNS1.Location =
    New-Object System.Drawing.Point(115,97)

$txtDNS1.Size =
    New-Object System.Drawing.Size(150,25)

$txtDNS1.Text = "8.8.8.8"

$grpIPv4.Controls.Add($txtDNS1)

# -----------------------------
# DNS 2
# -----------------------------

$lblDNS2 =
    New-Object System.Windows.Forms.Label

$lblDNS2.Text = "Alternate DNS:"

$lblDNS2.ForeColor =
    [System.Drawing.Color]::FromArgb(40,40,40)

$lblDNS2.Location =
    New-Object System.Drawing.Point(280,100)

$lblDNS2.AutoSize = $true

$grpIPv4.Controls.Add($lblDNS2)

$txtDNS2 =
    New-Object System.Windows.Forms.TextBox

$txtDNS2.Location =
    New-Object System.Drawing.Point(330,97)

$txtDNS2.Size =
    New-Object System.Drawing.Size(100,25)

$txtDNS2.Text = "1.1.1.1"

$grpIPv4.Controls.Add($txtDNS2)

# -----------------------------
# Apply / DHCP
# -----------------------------

$btnApplyIPv4 =
    New-Object System.Windows.Forms.Button

$btnApplyIPv4.Text =
    "APPLY STATIC IPv4"

$btnApplyIPv4.Location =
    New-Object System.Drawing.Point(15,140)

$btnApplyIPv4.Size =
    New-Object System.Drawing.Size(210,35)

$btnApplyIPv4.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)

$btnApplyIPv4.ForeColor = [System.Drawing.Color]::FromArgb(0,120,0)

$btnApplyIPv4.FlatStyle = "Flat"

$grpIPv4.Controls.Add($btnApplyIPv4)

$btnDHCP =
    New-Object System.Windows.Forms.Button

$btnDHCP.Text =
    "RESTORE DHCP"

$btnDHCP.Location =
    New-Object System.Drawing.Point(240,140)

$btnDHCP.Size =
    New-Object System.Drawing.Size(190,35)

$btnDHCP.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)

$btnDHCP.ForeColor =
    [System.Drawing.Color]::FromArgb(40,40,40)

$btnDHCP.FlatStyle = "Flat"

$grpIPv4.Controls.Add($btnDHCP)

# ============================================================
# NETWORK DISCOVERY PANEL
# ============================================================

$grpDiscovery =
    New-Object System.Windows.Forms.GroupBox

$grpDiscovery.Text =
    "Network Discovery"

$grpDiscovery.ForeColor =
    [System.Drawing.Color]::FromArgb(40,40,40)

$grpDiscovery.Location =
    New-Object System.Drawing.Point(520,215)

$grpDiscovery.Size =
    New-Object System.Drawing.Size(465,190)

$form.Controls.Add($grpDiscovery)

# -----------------------------
# Scan Range
# -----------------------------

$lblScanRange =
    New-Object System.Windows.Forms.Label

$lblScanRange.Text =
    "IP Range / CIDR:"

$lblScanRange.ForeColor =
    [System.Drawing.Color]::FromArgb(40,40,40)

$lblScanRange.Location =
    New-Object System.Drawing.Point(15,30)

$lblScanRange.AutoSize = $true

$grpDiscovery.Controls.Add($lblScanRange)

$txtScanRange =
    New-Object System.Windows.Forms.TextBox

$txtScanRange.Location =
    New-Object System.Drawing.Point(115,27)

$txtScanRange.Size =
    New-Object System.Drawing.Size(320,25)

$txtScanRange.Text = ""

$grpDiscovery.Controls.Add($txtScanRange)

# -----------------------------
# Hint
# -----------------------------

$lblScanHint =
    New-Object System.Windows.Forms.Label

$lblScanHint.Text =
    "Blank = Auto Detect | 192.168.1.0/24 | 192.168.1.1-192.168.1.100"

$lblScanHint.ForeColor =
    [System.Drawing.Color]::Gray

$lblScanHint.Location =
    New-Object System.Drawing.Point(15,60)

$lblScanHint.AutoSize = $true

$grpDiscovery.Controls.Add($lblScanHint)

# -----------------------------
# Scan Button
# -----------------------------

$btnScan =
    New-Object System.Windows.Forms.Button

$btnScan.Text =
    "SCAN NETWORK"

$btnScan.Location =
    New-Object System.Drawing.Point(15,95)

$btnScan.Size =
    New-Object System.Drawing.Size(170,40)

$btnScan.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)

$btnScan.ForeColor = [System.Drawing.Color]::FromArgb(0,120,0)

$btnScan.FlatStyle = "Flat"

$grpDiscovery.Controls.Add($btnScan)

$btnStopScan = New-Object System.Windows.Forms.Button
$btnStopScan.Text = "STOP SCAN"
$btnStopScan.Location = New-Object System.Drawing.Point(195,95)
$btnStopScan.Size = New-Object System.Drawing.Size(120,40)
$btnStopScan.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
$btnStopScan.ForeColor = [System.Drawing.Color]::FromArgb(190,0,0)
$btnStopScan.FlatStyle = "Flat"
$btnStopScan.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200,200,200)
$btnStopScan.Enabled = $false
$grpDiscovery.Controls.Add($btnStopScan)

# -----------------------------
# Scan Status
# -----------------------------

$lblScanStatus =
    New-Object System.Windows.Forms.Label

$lblScanStatus.Text =
    "Ready"

$lblScanStatus.ForeColor =
    [System.Drawing.Color]::Gray

$lblScanStatus.Location =
    New-Object System.Drawing.Point(15,145)

$lblScanStatus.AutoSize = $true

$grpDiscovery.Controls.Add($lblScanStatus)

# ============================================================
# OUTPUT
# ============================================================

$txtOutput =
    New-Object System.Windows.Forms.TextBox

$txtOutput.Location =
    New-Object System.Drawing.Point(30,425)

$txtOutput.Size =
    New-Object System.Drawing.Size(955,275)

$txtOutput.Multiline = $true

$txtOutput.ScrollBars = "Vertical"

$txtOutput.ReadOnly = $true

$txtOutput.BackColor = [System.Drawing.Color]::FromArgb(248,248,248)
$txtOutput.ForeColor = [System.Drawing.Color]::FromArgb(30,30,30)

$txtOutput.Font =
    New-Object System.Drawing.Font(
        "Consolas",
        10
    )

$form.Controls.Add($txtOutput)

# ============================================================
# BOTTOM BUTTONS
# ============================================================

$btnReport =
    New-ToolButton `
        "Generate Report" `
        30 `
        710 `
        180

$btnReload =
    New-ToolButton `
        "Refresh Adapters" `
        220 `
        710 `
        180

$btnExit =
    New-ToolButton `
        "EXIT" `
        805 `
        710 `
        180

$lblDeveloper = New-Object System.Windows.Forms.Label
$lblDeveloper.Text = "Developed by Md. Ahsanul Kabir Prince"
$lblDeveloper.Font = New-Object System.Drawing.Font(
    "Segoe UI",
    9,
    [System.Drawing.FontStyle]::Bold
)
$lblDeveloper.ForeColor = [System.Drawing.Color]::Red
$lblDeveloper.Location = New-Object System.Drawing.Point(30,755)
$lblDeveloper.AutoSize = $true
$form.Controls.Add($lblDeveloper)

# ============================================================
# BUTTON EVENTS
# ============================================================

$btnInfo.Add_Click({
    Get-NetworkInformation
})

$btnGateway.Add_Click({
    Test-Gateway
})

$btnDNS.Add_Click({
    Test-DNS
})

$btnInternet.Add_Click({
    Test-Internet
})

$btnLatency.Add_Click({
    Test-Latency
})

$btnFull.Add_Click({
    Run-FullDiagnosis
})

$btnFlush.Add_Click({
    Clear-DNSCache
})

$btnRenew.Add_Click({
    Renew-IP
})

$btnAdapterRestart.Add_Click({
    Restart-NetworkAdapter
})

$btnWinsock.Add_Click({
    Reset-Winsock
})

$btnTCP.Add_Click({
    Reset-TCPIP
})

$btnApplyIPv4.Add_Click({
    Set-StaticIPv4
})

$btnDHCP.Add_Click({
    Set-IPv4DHCP
})

$btnScan.Add_Click({
    Start-NetworkScan
})

$btnStopScan.Add_Click({
    Stop-NetworkScan
})

$btnReport.Add_Click({
    Generate-HTMLReport
})

$btnReload.Add_Click({

    Load-NetworkAdapters

    Add-Output "[+] Network adapters refreshed."
})

$btnExit.Add_Click({

    if ($script:ScanRunning) {
        Stop-NetworkScan
    }

    $form.Close()
})

# ============================================================
# ADAPTER CHANGE
# ============================================================

$cmbAdapter.Add_SelectedIndexChanged({

    try {

        $adapterName =
            Get-SelectedAdapterName

        if ($adapterName) {

            $config =
                Get-NetIPConfiguration `
                    -InterfaceAlias $adapterName `
                    -ErrorAction SilentlyContinue

            if ($config) {

                if ($config.IPv4Address) {

                    $txtIPv4.Text =
                        $config.IPv4Address.IPAddress

                    $txtPrefix.Text =
                        $config.IPv4Address.PrefixLength
                }

                if ($config.IPv4DefaultGateway) {

                    $txtGateway.Text =
                        $config.IPv4DefaultGateway.NextHop
                }

                if ($config.DnsServer.ServerAddresses) {

                    $dns =
                        $config.DnsServer.ServerAddresses

                    if ($dns.Count -ge 1) {
                        $txtDNS1.Text = $dns[0]
                    }

                    if ($dns.Count -ge 2) {
                        $txtDNS2.Text = $dns[1]
                    }
                }
            }
        }
    }
    catch {}
})

# ============================================================
# LIGHT THEME
# ============================================================

function Apply-LightTheme {
    param([System.Windows.Forms.Control]$Control)

    foreach ($child in $Control.Controls) {

        if ($child -is [System.Windows.Forms.GroupBox]) {
            $child.BackColor = [System.Drawing.Color]::White
            $child.ForeColor = [System.Drawing.Color]::FromArgb(40,40,40)
        }
        elseif ($child -is [System.Windows.Forms.Label]) {
            if ($child -ne $lblDeveloper) {
                $child.ForeColor = [System.Drawing.Color]::FromArgb(40,40,40)
            }
            $child.BackColor = [System.Drawing.Color]::White
        }
        elseif ($child -is [System.Windows.Forms.TextBox]) {
            $child.BackColor = [System.Drawing.Color]::White
            $child.ForeColor = [System.Drawing.Color]::FromArgb(30,30,30)
        }
        elseif ($child -is [System.Windows.Forms.ComboBox]) {
            $child.BackColor = [System.Drawing.Color]::White
            $child.ForeColor = [System.Drawing.Color]::FromArgb(30,30,30)
        }
        elseif ($child -is [System.Windows.Forms.Button]) {
            if ($child -ne $btnStopScan) {
                $child.BackColor = [System.Drawing.Color]::FromArgb(245,245,245)
                $child.ForeColor = [System.Drawing.Color]::FromArgb(30,30,30)
            }
            $child.FlatStyle = "Flat"
            $child.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200,200,200)
        }

        if ($child.Controls.Count -gt 0) {
            Apply-LightTheme $child
        }
    }
}

Apply-LightTheme $form

# Keep the intended accent colors after the generic light-theme pass.
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(30,30,30)
$lblDeveloper.ForeColor = [System.Drawing.Color]::Red
$btnStopScan.ForeColor = [System.Drawing.Color]::Red
$btnApplyIPv4.ForeColor = [System.Drawing.Color]::FromArgb(0,120,0)
$btnScan.ForeColor = [System.Drawing.Color]::FromArgb(0,120,0)

# ============================================================
# STARTUP
# ============================================================

Load-NetworkAdapters

Add-Output "========================================"
Add-Output " NETFORGE"
Add-Output " WINDOWS NETWORK TOOLKIT"
Add-Output "========================================"
Add-Output ""
Add-Output "[+] Network engine initialized."
Add-Output "[+] Network adapters loaded."
Add-Output "[+] IPv4 configuration ready."
Add-Output "[+] Fast network discovery ready."
Add-Output "[+] Stop Scan is available during discovery."
Add-Output ""
Add-Output "Select an adapter to begin."
Add-Output ""

# ============================================================
# RUN
# ============================================================

[void]$form.ShowDialog()