# Progress tracking

Completions are not a local checkbox. They are read back out of your actual
submission history on both providers, so problems you solved in a browser, or
years ago, are already counted the first time you open the roadmap.

## How a completion is counted

A problem counts for a **calendar day** when there is an accepted cloud
submission for it, in the currently selected language, on that day. The number
shown beside a problem is how many distinct days that happened — which is what
you want when you are re-grinding the same list.

LeetCode and NeetCode share one history, keyed by LeetCode slug. Ten accepts in
one day across both providers is one day. Their day boundaries differ though:
LeetCode's is your local timezone, NeetCode's is UTC, so a submission near
midnight can occasionally land on the adjacent day for one of them.

History is stored in `stdpath("cache")/meatcode/progress.json`, keyed by
language, then slug, then day, and stays readable offline.

## When it checks

Opening the roadmap or the LeetCode finder triggers a check for the selected
language.

The **first** check for a language walks each provider's full history:
LeetCode's account submission log, page by page, and NeetCode's daily activity
log — the same data behind its streak calendar. That is the slow one, and it
reports progress as it goes.

Every check after that only looks for submissions made since the last one. A
stored cursor — the last-seen LeetCode submission id, the last-checked NeetCode
day — means it fetches just what is new, so it stays cheap on every launch.
That is also how submissions made *outside* the plugin get picked up.

Each check announces itself when it starts and summarises when it finishes,
even when nothing changed, so a quiet "submissions up to date" means nothing
was missed. A provider you are not logged into is skipped silently.

Catalogs refresh in the background on the same trigger. The UI never blocks on
either: cached data renders immediately and is swapped out when newer data
lands.
