
# Table of Contents



Project Members: @curche @mikeryp @durwasa
Research Question :: @curche
EIO is a fiber built with <span class="underline">delimited continuation</span> while the \`kotlin\` implementation uses a promise/value

-   **research question:** can we do this with OC5/fibre? Through some rinse and repeat agent was able to find a flaw did not have a cancel interface. Opus pointed out that domains are not thread safe; opus pointed out
    
    \*\* Kotlin has a single thread, are continuations itself becomes non-thread safe. The continuation itself is not thread safe. After the cancellable implementation was implemented ecb5855d13c6a6518388b3d12c59b1e84669cd33
    
    then again I asked some other questions about EIO providing cancellable API. EIO does provide a similar API. The lightweight thread works but we used the EIO as a <span class="underline">drop in</span>.

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<tbody>
<tr>
<td class="org-left">Task</td>
<td class="org-left">Member</td>
<td class="org-left">Status</td>
<td class="org-left">notes about the section</td>
</tr>

<tr>
<td class="org-left">Abstract</td>
<td class="org-left">@all</td>
<td class="org-left">&#xa0;</td>
<td class="org-left">&#xa0;</td>
</tr>

<tr>
<td class="org-left">Goals</td>
<td class="org-left">@curche</td>
<td class="org-left">&#xa0;</td>
<td class="org-left">&#xa0;</td>
</tr>

<tr>
<td class="org-left">Background</td>
<td class="org-left">@all</td>
<td class="org-left">&#xa0;</td>
<td class="org-left">&#xa0;</td>
</tr>

<tr>
<td class="org-left">TU (Implementation)</td>
<td class="org-left">@mikeryp</td>
<td class="org-left">&#xa0;</td>
<td class="org-left">&#xa0;</td>
</tr>

<tr>
<td class="org-left">TU (Testing and Verification)</td>
<td class="org-left">@durwasa</td>
<td class="org-left">&#xa0;</td>
<td class="org-left">&#xa0;</td>
</tr>

<tr>
<td class="org-left">Reflections</td>
<td class="org-left">@all</td>
<td class="org-left">&#xa0;</td>
<td class="org-left">each person shall write one sentence for each subsection</td>
</tr>

<tr>
<td class="org-left">Conclusion</td>
<td class="org-left">@all</td>
<td class="org-left">&#xa0;</td>
<td class="org-left">&#xa0;</td>
</tr>

<tr>
<td class="org-left">Evalution</td>
<td class="org-left">@opus</td>
<td class="org-left">&#xa0;</td>
<td class="org-left">&#xa0;</td>
</tr>
</tbody>
</table>

