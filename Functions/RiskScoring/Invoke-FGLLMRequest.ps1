function Invoke-FGLLMRequest {
    <#
    .SYNOPSIS
        Sends a request to an LLM API (Anthropic Claude or OpenAI) and returns the response text.

    .DESCRIPTION
        Shared helper for all risk scoring LLM interactions. Supports both Anthropic Claude
        and OpenAI APIs. No sensitive data should ever be passed through this function —
        only organizational context discovery and classifier generation prompts.

    .PARAMETER Provider
        LLM provider: "Anthropic" or "OpenAI".

    .PARAMETER ApiKey
        API key for the chosen provider.

    .PARAMETER SystemPrompt
        System/instruction prompt that sets the LLM's behavior.

    .PARAMETER UserPrompt
        The user message to send.

    .PARAMETER Model
        Model name. Defaults to "claude-sonnet-4-20250514" for Anthropic, "gpt-4o" for OpenAI.

    .PARAMETER MaxTokens
        Maximum tokens in the response. Default: 4096.

    .PARAMETER Temperature
        Temperature for generation. Default: 0.3 (deterministic-ish for structured output).

    .EXAMPLE
        Invoke-FGLLMRequest -Provider "Anthropic" -ApiKey $key -SystemPrompt "You are a researcher." -UserPrompt "Research portofrotterdam.com"
    #>

    [alias("Invoke-LLMRequest")]
    [cmdletbinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Anthropic", "OpenAI")]
        [System.String]$Provider,

        [Parameter(Mandatory = $true)]
        [System.String]$ApiKey,

        [Parameter(Mandatory = $true)]
        [System.String]$SystemPrompt,

        [Parameter(Mandatory = $true)]
        [System.String]$UserPrompt,

        [Parameter(Mandatory = $false)]
        [System.String]$Model,

        [Parameter(Mandatory = $false)]
        [System.Int32]$MaxTokens = 4096,

        [Parameter(Mandatory = $false)]
        [System.Double]$Temperature = 0.3
    )

    # Set default model per provider
    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = switch ($Provider) {
            "Anthropic" { "claude-sonnet-4-20250514" }
            "OpenAI"    { "gpt-4o" }
        }
    }

    try {
        if ($Provider -eq "Anthropic") {
            # ─── Anthropic Messages API ───────────────────────────────
            $uri = "https://api.anthropic.com/v1/messages"

            $headers = @{
                "x-api-key"         = $ApiKey
                "anthropic-version" = "2023-06-01"
                "Content-Type"      = "application/json"
            }

            $body = @{
                model      = $Model
                max_tokens = $MaxTokens
                temperature = $Temperature
                system     = $SystemPrompt
                messages   = @(
                    @{
                        role    = "user"
                        content = $UserPrompt
                    }
                )
            } | ConvertTo-Json -Depth 10

            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop

            # Extract text from content blocks
            $text = ($response.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n"
            return $text
        }
        else {
            # ─── OpenAI Chat Completions API ──────────────────────────
            $uri = "https://api.openai.com/v1/chat/completions"

            $headers = @{
                "Authorization" = "Bearer $ApiKey"
                "Content-Type"  = "application/json"
            }

            $body = @{
                model       = $Model
                max_tokens  = $MaxTokens
                temperature = $Temperature
                messages    = @(
                    @{
                        role    = "system"
                        content = $SystemPrompt
                    },
                    @{
                        role    = "user"
                        content = $UserPrompt
                    }
                )
            } | ConvertTo-Json -Depth 10

            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ErrorAction Stop

            $text = $response.choices[0].message.content
            return $text
        }
    }
    catch {
        Write-Host "LLM API request failed: $_" -ForegroundColor Red
        throw "LLM API request to $Provider failed: $($_.Exception.Message)"
    }
}
