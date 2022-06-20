<#
MIT License

Copyright (c) 2022 Maatschap Fortigi. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

$Base = @( Get-ChildItem -Path $PSScriptRoot\Base\*.ps1 -ErrorAction SilentlyContinue)
$Generic = @( Get-ChildItem -Path $PSScriptRoot\Generic\*.ps1 -ErrorAction SilentlyContinue)
$Specific = @( Get-ChildItem -Path $PSScriptRoot\Specific\*.ps1 -ErrorAction SilentlyContinue)

#Dot source the files
Foreach ($import in @($Base + $Generic + $Specific)) {
    Try {
        . $import.fullname
    }
    Catch {
        throw ("Failed to import function $($import.fullname): $_")
    }
}

Export-ModuleMember -Function * -Alias *



























