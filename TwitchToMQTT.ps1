Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- 1. CONFIGURATION ---
$MqttPath = Join-Path $PSScriptRoot "MQTTnet.dll"
if (!(Test-Path $MqttPath)) { 
    [System.Windows.Forms.MessageBox]::Show("Manque : $MqttPath"); exit 
}
Add-Type -Path $MqttPath

# --- 2. INTERFACE (Version Stable) ---
$form = New-Object Windows.Forms.Form
$form.Text = "Twitch to MQTT - by CAD Sanctuary"; $form.Size = "760,650"; $form.BackColor = [Drawing.Color]::FromArgb(30, 30, 30); $form.ForeColor = "White"

# ... (Champs de saisie inchangés pour gagner de la place) ...
$txtChan = New-Object Windows.Forms.TextBox; $txtChan.Location = "10,35"; $txtChan.Width = 200; $txtChan.Text = "votre_chaine"; $form.Controls.Add($txtChan)
$txtMQTT = New-Object Windows.Forms.TextBox; $txtMQTT.Location = "220,35"; $txtMQTT.Width = 150; $txtMQTT.Text = "127.0.0.1:1883"; $form.Controls.Add($txtMQTT)
$txtTopic = New-Object Windows.Forms.TextBox; $txtTopic.Location = "380,35"; $txtTopic.Width = 150; $txtTopic.Text = "twitch/chat"; $form.Controls.Add($txtTopic)
$txtUser = New-Object Windows.Forms.TextBox; $txtUser.Location = "10,90"; $txtUser.Text = "admin"; $form.Controls.Add($txtUser)
$txtPass = New-Object Windows.Forms.TextBox; $txtPass.Location = "180,90"; $txtPass.PasswordChar = "*"; $txtPass.Text = "password"; $form.Controls.Add($txtPass)
$indT = New-Object Windows.Forms.Label; $indT.Location = "360,92"; $indT.Size = "20,20"; $indT.BackColor = "Firebrick"; $indT.Text = "T"; $form.Controls.Add($indT)
$indM = New-Object Windows.Forms.Label; $indM.Location = "385,92"; $indM.Size = "20,20"; $indM.BackColor = "Firebrick"; $indM.Text = "M"; $form.Controls.Add($indM)
$output = New-Object Windows.Forms.TextBox; $output.Multiline=$true; $output.Location="10,130"; $output.Size="725,450"; $output.BackColor="Black"; $output.ForeColor="LimeGreen"; $output.ReadOnly=$true; $form.Controls.Add($output)
$btnStart = New-Object Windows.Forms.Button; $btnStart.Text="START"; $btnStart.Location="430,85"; $btnStart.BackColor="ForestGreen"; $form.Controls.Add($btnStart)
$btnStop = New-Object Windows.Forms.Button; $btnStop.Text="STOP"; $btnStop.Location="540,85"; $btnStop.Enabled=$false; $form.Controls.Add($btnStop)

# --- 3. LOGIQUE DU JOB ---
$script:job = $null
$jobTimer = New-Object Windows.Forms.Timer; $jobTimer.Interval = 200
$jobTimer.Add_Tick({
    if ($script:job) {
        $data = Receive-Job -Job $script:job
        foreach ($d in $data) {
            if ($d -eq "__TWITCH_OK__") { $indT.BackColor="Lime" }
            elseif ($d -eq "__MQTT_OK__") { $indM.BackColor="Lime" }
            else { $output.AppendText($d + "`r`n"); $output.SelectionStart = $output.TextLength; $output.ScrollToCaret() }
        }
    }
})

$btnStart.Add_Click({
    $chans = $txtChan.Text; $broker = $txtMQTT.Text; $topic = $txtTopic.Text; $u = $txtUser.Text; $p = $txtPass.Text; $root = $PSScriptRoot
    $btnStart.Enabled = $false; $btnStop.Enabled = $true
    $indT.BackColor = "Orange"; $indM.BackColor = "Orange"

    $script:job = Start-Job -ScriptBlock {
        param($chans, $broker, $topic, $mUser, $mPass, $root)
        Add-Type -Path (Join-Path $root "MQTTnet.dll")
        $channels = $chans.Split(",") | % { $_.Trim().ToLower() }

        # FONCTION MQTT CORRIGÉE (Elle renvoie le CLIENT)
        function Get-MqttClient {
            $factory = [MQTTnet.MqttFactory]::new()
            $client = $factory.CreateMqttClient()
            $parts = $broker.Split(':')
            $opts = [MQTTnet.Client.MqttClientOptionsBuilder]::new()
            $null = $opts.WithTcpServer($parts[0], ([int]$parts[1] ? [int]$parts[1] : 1883))
            $null = $opts.WithClientId("PS_$(Get-Random)")
            if (![string]::IsNullOrEmpty($mUser)) { $null = $opts.WithCredentials($mUser, $mPass) }
            # On se connecte, mais on renvoie le CLIENT ($client)
            $null = $client.ConnectAsync($opts.Build(), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            return $client
        }

        function Get-TwitchWs {
            $ws = [System.Net.WebSockets.ClientWebSocket]::new()
            $ws.ConnectAsync([Uri]"wss://irc-ws.chat.twitch.tv:443", [System.Threading.CancellationToken]::None).Wait()
            $send = { param($m) $b=[System.Text.Encoding]::UTF8.GetBytes($m+"`r`n"); $ws.SendAsync([ArraySegment[byte]]$b,"Text",$true,[System.Threading.CancellationToken]::None).Wait() }
            &$send "PASS SCHMOOPIIE"; &$send "NICK justinfan$(Get-Random)"
            foreach($c in $channels){ &$send "JOIN #$c" }
            return $ws
        }

        $mqtt = Get-MqttClient; if($mqtt.IsConnected){ Write-Output "__MQTT_OK__" }
        $ws = Get-TwitchWs; if($ws.State -eq "Open"){ Write-Output "__TWITCH_OK__" }

        $buf = New-Object byte[] 8192
        while($true) {
            try {
                if(!$ws -or $ws.State -ne "Open"){ $ws = Get-TwitchWs; Write-Output "__TWITCH_OK__" }
                if(!$mqtt -or !$mqtt.IsConnected){ $mqtt = Get-MqttClient; Write-Output "__MQTT_OK__" }

                $r = $ws.ReceiveAsync([ArraySegment[byte]]$buf, [System.Threading.CancellationToken]::None).Result
                if($r.Count -gt 0) {
                    $raw = [System.Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
                    foreach($line in $raw.Split("`n")) {
                        $line = $line.Trim()
                        # On n'envoie MQTT QUE si c'est un message PRIVMSG
                        if($line -match ":(?<u1>[^! ]+)!.* PRIVMSG #(?<c1>[^ ]+) :(?<m1>.*)"){
                            $data = @{user=$matches['u1']; msg=$matches['m1']} | ConvertTo-Json -Compress
                            Write-Output $data
                            
                            # PUBLICATION (Sur le bon objet $mqtt)
                            if($mqtt.IsConnected) {
                                $mb = [MQTTnet.MqttApplicationMessageBuilder]::new()
                                $null = $mb.WithTopic($topic)
                                $null = $mb.WithPayload([System.Text.Encoding]::UTF8.GetBytes($data))
                                $null = $mqtt.PublishAsync($mb.Build(), [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
                            }
                        }
                        if($line.StartsWith("PING")){ 
                            $pb = [System.Text.Encoding]::UTF8.GetBytes("PONG :tmi.twitch.tv`r`n")
                            $ws.SendAsync([ArraySegment[byte]]$pb,"Text",$true,[System.Threading.CancellationToken]::None).Wait()
                        }
                    }
                }
            } catch { Write-Output "ERROR: $($_.Exception.Message)"; Start-Sleep 1 }
        }
    } -ArgumentList $chans, $broker, $topic, $u, $p, $root
    $jobTimer.Start()
})

$btnStop.Add_Click({ $jobTimer.Stop(); Stop-Job $script:job -Force; $btnStart.Enabled=$true; $indT.BackColor="Firebrick"; $indM.BackColor="Firebrick" })
$form.ShowDialog()