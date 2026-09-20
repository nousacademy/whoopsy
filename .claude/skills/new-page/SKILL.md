---
name: new-page
description: Use when adding a page under Sources/Whoopsy/Presentation/Screens/ — a new tab, a pushed detail screen, or an overlay reached from an existing screen. Walks the three places a page must be wired (its view model in MainContainerView, its use cases in DIContainer, its row in CLAUDE.md's ## Pages table) so a new screen never reaches for a global.
---

# New Page Skill
When user asks for a new page:
1. Ask for route and content requirements
2. Create the component file
3. Wire navigation
4. Update CLAUDE.md under ## Pages