# Fix agent step limit & keyboard dismissal in chat

**Problems**

1. When the agent uses tools (like "nearest subway"), it often loops through many searches and hits the step limit, leaving the user with a raw "I reached the maximum number of reasoning steps" error instead of a helpful answer.
2. The chat keyboard sometimes can't be dismissed — the swipe-to-dismiss gesture conflicts with the scrolling reasoning panel, and the "Done" button is hidden behind iOS text suggestions.

**Fixes**

Agent behavior

- When the agent runs out of steps, synthesize a clean, user-friendly final answer from the observations it already gathered (e.g. "The nearest subway stations are Peel and Guy-Concordia in Montréal") instead of dumping the raw last observation with an error message.
- Improve the agent's instructions so it calls `location.current` first when a query depends on "nearest / near me", and prefers giving a Final Answer once it has enough information rather than re-searching.
- Raise the default reasoning budget slightly so multi-step location questions can complete.

Keyboard dismissal

- Add a tap-anywhere-to-dismiss gesture on the chat message area so tapping the conversation always closes the keyboard.
- Add a visible "chevron down" dismiss button next to the text field when the keyboard is open, as a reliable fallback that isn't hidden by iOS suggestions.
- Keep the existing swipe-to-dismiss and the toolbar "Done" button.

**Result**

- Asking "Where is the nearest subway?" returns a real answer listing the closest stations.
- The keyboard can always be closed by tapping the chat, swiping down, or tapping the new dismiss button.

