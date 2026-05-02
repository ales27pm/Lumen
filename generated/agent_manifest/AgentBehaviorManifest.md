# Lumen Agent Behavior Manifest

## Source Integrity
- Commit: `51b4f67fe27ed71ce89acf1a0265c9c79c49b4a5`
- Source files: 13

## Model Fleet Slots
- Contract version: `2026.04.29`
### `cortex`
- Role: orchestrator
- Purpose: intent routing
- Responsibilities:
  - intent routing
  - model coordination
  - task planning
  - tool selection
- Accepts: User request plus manifest routing matrix, available tools, memory context, and prior agent state.
- Returns: Intent classification, selectedToolID or target slot, approval requirement, and concise routing summary.
- Calls: embedding, executor, mimicry, mouth, rem
- Called by: rem

### `embedding`
- Role: embedding
- Purpose: Perform the embedding role defined by the Lumen model fleet contract.
- Accepts: Role-specific input defined by the fleet contract and AgentBehaviorManifest.
- Returns: Role-specific output defined by the fleet contract and AgentBehaviorManifest.
- Calls: none
- Called by: cortex

### `executor`
- Role: tool_executor
- Purpose: strict JSON generation
- Responsibilities:
  - approval boundary enforcement
  - strict JSON generation
  - tool argument validation
- Accepts: Approved Cortex plan, exact tool ID, argument candidates, permission state, and approval state.
- Returns: Strict JSON tool call, clarification request, approval request, or structured tool result.
- Calls: mouth, rem
- Called by: cortex, rem

### `mimicry`
- Role: tone_adapter
- Purpose: tone detection
- Responsibilities:
  - response rewriting
  - style adaptation
  - tone detection
- Accepts: Draft response, user style hints, locale, tone preferences, and safety constraints.
- Returns: Style-adjusted user-facing text or style profile that preserves facts and safety boundaries.
- Calls: mouth
- Called by: cortex

### `mouth`
- Role: user_response
- Purpose: final user-facing response
- Responsibilities:
  - clarification
  - final user-facing response
  - spoken output
- Accepts: Tool result, user-visible state, style profile, and safety/sentinel constraints.
- Returns: Final user-facing text with no private reasoning, raw tool JSON, or forbidden sentinels.
- Calls: none
- Called by: cortex, executor, mimicry

### `rem`
- Role: idle_reflection
- Purpose: memory pruning
- Responsibilities:
  - dataset generation
  - failure analysis
  - manifest audit
  - memory pruning
- Accepts: Audit failure, conversation summary, memory candidates, freshness policy, and manifest context.
- Returns: Repair sample, memory decision, freshness classification, or runtime drift recommendation.
- Calls: cortex, executor
- Called by: cortex, executor

## Tools
### `alarm.authorization_status`
- Display name: Alarm Auth Status
- Description: Check AlarmKit authorization state. Args: none.
- Requires approval: False
- Permission key: NSAlarmKitUsageDescription
- Arguments: none
- Example: Use `alarm.authorization_status` only when the user intent maps to this manifest tool and all required arguments are known.

### `alarm.cancel`
- Display name: Cancel Alarm
- Description: Cancel a scheduled alarm. Args: id UUID or title fallback.
- Requires approval: True
- Permission key: NSAlarmKitUsageDescription
- Arguments:
  - `id`: string, required. Inferred from ToolDefinition description Args contract: id UUID or title fallback
  - `title`: string, required. Inferred from ToolDefinition description Args contract: id UUID or title fallback
- Example: Use `alarm.cancel` only when the user intent maps to this manifest tool and all required arguments are known.

### `alarm.countdown`
- Display name: Start Countdown
- Description: Create a countdown alarm. Args: title, durationSeconds.
- Requires approval: True
- Permission key: NSAlarmKitUsageDescription
- Arguments:
  - `title`: string, required. Inferred from ToolDefinition description Args contract: title, durationSeconds
  - `durationSeconds`: number, required. Inferred from ToolDefinition description Args contract: title, durationSeconds
- Example: Use `alarm.countdown` only when the user intent maps to this manifest tool and all required arguments are known.

### `alarm.list`
- Display name: List Alarms
- Description: List active AlarmKit alarms. Args: none.
- Requires approval: False
- Permission key: NSAlarmKitUsageDescription
- Arguments: none
- Example: Use `alarm.list` only when the user intent maps to this manifest tool and all required arguments are known.

### `alarm.pause`
- Display name: Pause Alarm
- Description: Pause an alarm. Args: id UUID.
- Requires approval: True
- Permission key: NSAlarmKitUsageDescription
- Arguments:
  - `id`: string, required. Inferred from ToolDefinition description Args contract: id UUID
- Example: Use `alarm.pause` only when the user intent maps to this manifest tool and all required arguments are known.

### `alarm.request_authorization`
- Display name: Request Alarm Auth
- Description: Request permission to use AlarmKit alarms. Args: none.
- Requires approval: True
- Permission key: NSAlarmKitUsageDescription
- Arguments: none
- Example: Use `alarm.request_authorization` only when the user intent maps to this manifest tool and all required arguments are known.

### `alarm.resume`
- Display name: Resume Alarm
- Description: Resume a paused alarm. Args: id UUID.
- Requires approval: True
- Permission key: NSAlarmKitUsageDescription
- Arguments:
  - `id`: string, required. Inferred from ToolDefinition description Args contract: id UUID
- Example: Use `alarm.resume` only when the user intent maps to this manifest tool and all required arguments are known.

### `alarm.schedule`
- Display name: Schedule Alarm
- Description: Schedule an AlarmKit alarm. Args: title, inMinutes or timestamp, optional repeats, snoozeMinutes.
- Requires approval: True
- Permission key: NSAlarmKitUsageDescription
- Arguments:
  - `title`: string, required. Inferred from ToolDefinition description Args contract: title, inMinutes or timestamp, optional repeats, snoozeMinutes
  - `inMinutes`: number, required. Inferred from ToolDefinition description Args contract: title, inMinutes or timestamp, optional repeats, snoozeMinutes
  - `timestamp`: string, required. Inferred from ToolDefinition description Args contract: title, inMinutes or timestamp, optional repeats, snoozeMinutes
  - `repeats`: bool, optional. Inferred from ToolDefinition description Args contract: title, inMinutes or timestamp, optional repeats, snoozeMinutes
  - `snoozeMinutes`: number, optional. Inferred from ToolDefinition description Args contract: title, inMinutes or timestamp, optional repeats, snoozeMinutes
- Example: Use `alarm.schedule` only when the user intent maps to this manifest tool and all required arguments are known.

### `alarm.snooze`
- Display name: Snooze Alarm
- Description: Snooze an alerting alarm. Args: id UUID.
- Requires approval: True
- Permission key: NSAlarmKitUsageDescription
- Arguments:
  - `id`: string, required. Inferred from ToolDefinition description Args contract: id UUID
- Example: Use `alarm.snooze` only when the user intent maps to this manifest tool and all required arguments are known.

### `alarm.stop`
- Display name: Stop Alarm
- Description: Stop an alerting alarm. Args: id UUID.
- Requires approval: True
- Permission key: NSAlarmKitUsageDescription
- Arguments:
  - `id`: string, required. Inferred from ToolDefinition description Args contract: id UUID
- Example: Use `alarm.stop` only when the user intent maps to this manifest tool and all required arguments are known.

### `calendar.create`
- Display name: Create Event
- Description: Add an event to your calendar. Args: title, startsInMinutes.
- Requires approval: True
- Permission key: NSCalendarsFullAccessUsageDescription
- Arguments:
  - `title`: string, required. Inferred from ToolDefinition description Args contract: title, startsInMinutes
  - `startsInMinutes`: number, required. Inferred from ToolDefinition description Args contract: title, startsInMinutes
- Example: Use `calendar.create` only when the user intent maps to this manifest tool and all required arguments are known.

### `calendar.list`
- Display name: List Events
- Description: Read upcoming calendar events. Args: none.
- Requires approval: False
- Permission key: NSCalendarsFullAccessUsageDescription
- Arguments: none
- Example: Use `calendar.list` only when the user intent maps to this manifest tool and all required arguments are known.

### `camera.capture`
- Display name: Capture Image
- Description: Take a photo with the device camera. Args: none.
- Requires approval: True
- Permission key: NSCameraUsageDescription
- Arguments: none
- Example: Use `camera.capture` only when the user intent maps to this manifest tool and all required arguments are known.

### `contacts.search`
- Display name: Search Contacts
- Description: Find a contact by name. Args: query. Only use for the user's address book, not web people search.
- Requires approval: False
- Permission key: NSContactsUsageDescription
- Arguments:
  - `query`: string, required. Inferred from ToolDefinition description Args contract: query
- Example: Use `contacts.search` only when the user intent maps to this manifest tool and all required arguments are known.

### `files.read`
- Display name: Read File
- Description: Read a previously imported local document by name. Args: name. Do not use for attached files already visible in the current prompt.
- Requires approval: False
- Permission key: none
- Arguments:
  - `name`: string, required. Inferred from ToolDefinition description Args contract: name
- Example: Use `files.read` only when the user intent maps to this manifest tool and all required arguments are known.

### `health.summary`
- Display name: Health Summary
- Description: Read steps, sleep, heart rate, energy, and distance. Args: none.
- Requires approval: False
- Permission key: NSHealthShareUsageDescription
- Arguments: none
- Example: Use `health.summary` only when the user intent maps to this manifest tool and all required arguments are known.

### `location.current`
- Display name: Current Location
- Description: Get the user's current GPS location. Args: none. Use before nearby/local map searches when location context is needed.
- Requires approval: False
- Permission key: NSLocationWhenInUseUsageDescription
- Arguments: none
- Example: Use `location.current` only when the user intent maps to this manifest tool and all required arguments are known.

### `mail.draft`
- Display name: Draft Email
- Description: Compose an email draft using the system mail composer. Args: to or recipient or email, subject, body or message or text.
- Requires approval: True
- Permission key: none
- Arguments:
  - `to`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or email, subject, body or message or text
  - `recipient`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or email, subject, body or message or text
  - `email`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or email, subject, body or message or text
  - `subject`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or email, subject, body or message or text
  - `body`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or email, subject, body or message or text
  - `message`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or email, subject, body or message or text
  - `text`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or email, subject, body or message or text
- Example: Use `mail.draft` only when the user intent maps to this manifest tool and all required arguments are known.

### `maps.directions`
- Display name: Get Directions
- Description: Open Apple Maps directions to a real destination. Args: destination. Use only for navigation/route requests.
- Requires approval: False
- Permission key: none
- Arguments:
  - `destination`: string, required. Inferred from ToolDefinition description Args contract: destination
- Example: Use `maps.directions` only when the user intent maps to this manifest tool and all required arguments are known.

### `maps.search`
- Display name: Search Nearby
- Description: Find nearby/local places in Apple Maps. Args: query. Use only for local places like coffee near me, pharmacy nearby, closest hardware store, addresses, or directions. Do not use for DIY, tutorials, research, articles, or general web search.
- Requires approval: False
- Permission key: NSLocationWhenInUseUsageDescription
- Arguments:
  - `query`: string, required. Inferred from ToolDefinition description Args contract: query
- Example: Use `maps.search` only when the user intent maps to this manifest tool and all required arguments are known.

### `memory.recall`
- Display name: Recall Memory
- Description: Search stored memories about the user. Args: query. Not for web search.
- Requires approval: False
- Permission key: none
- Arguments:
  - `query`: string, required. Inferred from ToolDefinition description Args contract: query
- Example: Use `memory.recall` only when the user intent maps to this manifest tool and all required arguments are known.

### `memory.save`
- Display name: Save Memory
- Description: Store a user fact or preference for future recall. Args: content, kind.
- Requires approval: False
- Permission key: none
- Arguments:
  - `content`: string, required. Inferred from ToolDefinition description Args contract: content, kind
  - `kind`: string, required. Inferred from ToolDefinition description Args contract: content, kind
- Example: Use `memory.save` only when the user intent maps to this manifest tool and all required arguments are known.

### `messages.draft`
- Display name: Draft Message
- Description: Compose an iMessage/SMS draft. Args: to or recipient or number, body or message or text.
- Requires approval: True
- Permission key: none
- Arguments:
  - `to`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or number, body or message or text
  - `recipient`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or number, body or message or text
  - `number`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or number, body or message or text
  - `body`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or number, body or message or text
  - `message`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or number, body or message or text
  - `text`: string, required. Inferred from ToolDefinition description Args contract: to or recipient or number, body or message or text
- Example: Use `messages.draft` only when the user intent maps to this manifest tool and all required arguments are known.

### `motion.activity`
- Display name: Motion Activity
- Description: Detect recent device motion activity such as walking/running. Args: none.
- Requires approval: False
- Permission key: NSMotionUsageDescription
- Arguments: none
- Example: Use `motion.activity` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.attachments.list`
- Display name: List Outlook Attachments
- Description: List attachment metadata for one Outlook message. Args: messageId or id.
- Requires approval: False
- Permission key: none
- Arguments:
  - `messageId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
  - `id`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
- Example: Use `outlook.attachments.list` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.draft.create`
- Display name: Create Outlook Draft
- Description: Create a saved Outlook draft through Microsoft Graph. Args: to, subject, body.
- Requires approval: True
- Permission key: none
- Arguments:
  - `to`: string, required. Inferred from ToolDefinition description Args contract: to, subject, body
  - `subject`: string, required. Inferred from ToolDefinition description Args contract: to, subject, body
  - `body`: string, required. Inferred from ToolDefinition description Args contract: to, subject, body
- Example: Use `outlook.draft.create` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.folders.list`
- Display name: List Outlook Folders
- Description: List Outlook/Hotmail mail folders with unread and total counts. Args: optional includeHidden true/false.
- Requires approval: False
- Permission key: none
- Arguments:
  - `includeHidden`: string, optional. Inferred from ToolDefinition description Args contract: optional includeHidden true/false
  - `false`: string, optional. Inferred from ToolDefinition description Args contract: optional includeHidden true/false
- Example: Use `outlook.folders.list` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.mail.send`
- Display name: Send Outlook Email
- Description: Send an Outlook email through Microsoft Graph. Args: to, subject, body. Requires explicit approval.
- Requires approval: True
- Permission key: none
- Arguments:
  - `to`: string, required. Inferred from ToolDefinition description Args contract: to, subject, body
  - `subject`: string, required. Inferred from ToolDefinition description Args contract: to, subject, body
  - `body`: string, required. Inferred from ToolDefinition description Args contract: to, subject, body
- Example: Use `outlook.mail.send` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.message.archive`
- Display name: Archive Outlook Message
- Description: Move an Outlook message to Archive. Args: messageId or id. Requires explicit approval.
- Requires approval: True
- Permission key: none
- Arguments:
  - `messageId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
  - `id`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
- Example: Use `outlook.message.archive` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.message.delete`
- Display name: Delete Outlook Message
- Description: Delete an Outlook message. Args: messageId or id. Requires explicit approval.
- Requires approval: True
- Permission key: none
- Arguments:
  - `messageId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
  - `id`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
- Example: Use `outlook.message.delete` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.message.forward`
- Display name: Forward Outlook Message
- Description: Forward an Outlook message. Args: messageId or id, to, optional body/comment. Requires explicit approval.
- Requires approval: True
- Permission key: none
- Arguments:
  - `messageId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, to, optional body/comment
  - `id`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, to, optional body/comment
  - `to`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, to, optional body/comment
  - `body`: string, optional. Inferred from ToolDefinition description Args contract: messageId or id, to, optional body/comment
  - `comment`: string, optional. Inferred from ToolDefinition description Args contract: messageId or id, to, optional body/comment
- Example: Use `outlook.message.forward` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.message.mark_read`
- Display name: Mark Outlook Read
- Description: Mark an Outlook message as read. Args: messageId or id. Requires explicit approval.
- Requires approval: True
- Permission key: none
- Arguments:
  - `messageId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
  - `id`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
- Example: Use `outlook.message.mark_read` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.message.mark_unread`
- Display name: Mark Outlook Unread
- Description: Mark an Outlook message as unread. Args: messageId or id. Requires explicit approval.
- Requires approval: True
- Permission key: none
- Arguments:
  - `messageId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
  - `id`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
- Example: Use `outlook.message.mark_unread` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.message.move`
- Display name: Move Outlook Message
- Description: Move an Outlook message to a folder. Args: messageId or id, destination or destinationId. Requires explicit approval.
- Requires approval: True
- Permission key: none
- Arguments:
  - `messageId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, destination or destinationId
  - `id`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, destination or destinationId
  - `destination`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, destination or destinationId
  - `destinationId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, destination or destinationId
- Example: Use `outlook.message.move` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.message.read`
- Display name: Read Outlook Message
- Description: Read one Outlook message body by id. Args: messageId or id.
- Requires approval: False
- Permission key: none
- Arguments:
  - `messageId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
  - `id`: string, required. Inferred from ToolDefinition description Args contract: messageId or id
- Example: Use `outlook.message.read` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.message.reply`
- Display name: Reply Outlook Message
- Description: Reply to an Outlook message. Args: messageId or id, body/comment. Requires explicit approval.
- Requires approval: True
- Permission key: none
- Arguments:
  - `messageId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, body/comment
  - `id`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, body/comment
  - `body`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, body/comment
  - `comment`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, body/comment
- Example: Use `outlook.message.reply` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.message.reply_all`
- Display name: Reply All Outlook Message
- Description: Reply-all to an Outlook message. Args: messageId or id, body/comment. Requires explicit approval.
- Requires approval: True
- Permission key: none
- Arguments:
  - `messageId`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, body/comment
  - `id`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, body/comment
  - `body`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, body/comment
  - `comment`: string, required. Inferred from ToolDefinition description Args contract: messageId or id, body/comment
- Example: Use `outlook.message.reply_all` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.messages.list`
- Display name: List Outlook Messages
- Description: List recent Outlook messages. Args: optional folder or folderId, limit, unreadOnly.
- Requires approval: False
- Permission key: none
- Arguments:
  - `folder`: string, optional. Inferred from ToolDefinition description Args contract: optional folder or folderId, limit, unreadOnly
  - `folderId`: string, optional. Inferred from ToolDefinition description Args contract: optional folder or folderId, limit, unreadOnly
  - `limit`: number, optional. Inferred from ToolDefinition description Args contract: optional folder or folderId, limit, unreadOnly
  - `unreadOnly`: string, optional. Inferred from ToolDefinition description Args contract: optional folder or folderId, limit, unreadOnly
- Example: Use `outlook.messages.list` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.messages.search`
- Display name: Search Outlook Messages
- Description: Search Outlook mail with Microsoft Graph. Args: query, optional folder/folderId, limit.
- Requires approval: False
- Permission key: none
- Arguments:
  - `query`: string, required. Inferred from ToolDefinition description Args contract: query, optional folder/folderId, limit
  - `folder`: string, optional. Inferred from ToolDefinition description Args contract: query, optional folder/folderId, limit
  - `folderId`: string, optional. Inferred from ToolDefinition description Args contract: query, optional folder/folderId, limit
  - `limit`: number, optional. Inferred from ToolDefinition description Args contract: query, optional folder/folderId, limit
- Example: Use `outlook.messages.search` only when the user intent maps to this manifest tool and all required arguments are known.

### `outlook.status`
- Display name: Outlook Status
- Description: Check whether the Microsoft Graph Outlook account is signed in. Args: none.
- Requires approval: False
- Permission key: none
- Arguments: none
- Example: Use `outlook.status` only when the user intent maps to this manifest tool and all required arguments are known.

### `phone.call`
- Display name: Start Call
- Description: Open the phone dialer for a number. Args: number. Never use for general lookup.
- Requires approval: True
- Permission key: none
- Arguments:
  - `number`: string, required. Inferred from ToolDefinition description Args contract: number
- Example: Use `phone.call` only when the user intent maps to this manifest tool and all required arguments are known.

### `photos.search`
- Display name: Search Photos
- Description: Search the user's photo library by date/category terms. Args: query. Not for web image search.
- Requires approval: False
- Permission key: NSPhotoLibraryUsageDescription
- Arguments:
  - `query`: string, required. Inferred from ToolDefinition description Args contract: query
- Example: Use `photos.search` only when the user intent maps to this manifest tool and all required arguments are known.

### `rag.index_files`
- Display name: Reindex Files
- Description: Rebuild the index for imported files and PDFs. Args: none.
- Requires approval: False
- Permission key: none
- Arguments: none
- Example: Use `rag.index_files` only when the user intent maps to this manifest tool and all required arguments are known.

### `rag.index_photos`
- Display name: Reindex Photos
- Description: Rebuild the monthly photo metadata index. Args: months.
- Requires approval: False
- Permission key: NSPhotoLibraryUsageDescription
- Arguments:
  - `months`: number, required. Inferred from ToolDefinition description Args contract: months
- Example: Use `rag.index_photos` only when the user intent maps to this manifest tool and all required arguments are known.

### `rag.search`
- Display name: Search Personal Data
- Description: Semantic search across indexed local files, PDFs, notes, and photo metadata. Args: query, optional limit. Not for internet search.
- Requires approval: False
- Permission key: none
- Arguments:
  - `query`: string, required. Inferred from ToolDefinition description Args contract: query, optional limit
  - `limit`: number, optional. Inferred from ToolDefinition description Args contract: query, optional limit
- Example: Use `rag.search` only when the user intent maps to this manifest tool and all required arguments are known.

### `reminders.create`
- Display name: Add Reminder
- Description: Create a new reminder. Args: title.
- Requires approval: True
- Permission key: NSRemindersFullAccessUsageDescription
- Arguments:
  - `title`: string, required. Inferred from ToolDefinition description Args contract: title
- Example: Use `reminders.create` only when the user intent maps to this manifest tool and all required arguments are known.

### `reminders.list`
- Display name: List Reminders
- Description: Read pending reminders. Args: none.
- Requires approval: False
- Permission key: NSRemindersFullAccessUsageDescription
- Arguments: none
- Example: Use `reminders.list` only when the user intent maps to this manifest tool and all required arguments are known.

### `trigger.cancel`
- Display name: Cancel Trigger
- Description: Cancel a scheduled agent run. Args: title or id.
- Requires approval: True
- Permission key: none
- Arguments:
  - `title`: string, required. Inferred from ToolDefinition description Args contract: title or id
  - `id`: string, required. Inferred from ToolDefinition description Args contract: title or id
- Example: Use `trigger.cancel` only when the user intent maps to this manifest tool and all required arguments are known.

### `trigger.create`
- Display name: Schedule Agent Run
- Description: Schedule a background agent run. Args: title, prompt, schedule, plus inMinutes/atTime/intervalSeconds/beforeMinutes depending on schedule.
- Requires approval: True
- Permission key: none
- Arguments:
  - `title`: string, required. Inferred from ToolDefinition description Args contract: title, prompt, schedule, plus inMinutes/atTime/intervalSeconds/beforeMinutes depending on schedule
  - `prompt`: string, required. Inferred from ToolDefinition description Args contract: title, prompt, schedule, plus inMinutes/atTime/intervalSeconds/beforeMinutes depending on schedule
  - `schedule`: string, required. Inferred from ToolDefinition description Args contract: title, prompt, schedule, plus inMinutes/atTime/intervalSeconds/beforeMinutes depending on schedule
  - `inMinutes`: number, required. Inferred from ToolDefinition description Args contract: title, prompt, schedule, plus inMinutes/atTime/intervalSeconds/beforeMinutes depending on schedule
  - `atTime`: string, required. Inferred from ToolDefinition description Args contract: title, prompt, schedule, plus inMinutes/atTime/intervalSeconds/beforeMinutes depending on schedule
  - `intervalSeconds`: number, required. Inferred from ToolDefinition description Args contract: title, prompt, schedule, plus inMinutes/atTime/intervalSeconds/beforeMinutes depending on schedule
  - `beforeMinutes`: number, required. Inferred from ToolDefinition description Args contract: title, prompt, schedule, plus inMinutes/atTime/intervalSeconds/beforeMinutes depending on schedule
- Example: Use `trigger.create` only when the user intent maps to this manifest tool and all required arguments are known.

### `trigger.list`
- Display name: List Triggers
- Description: Show active scheduled agent runs. Args: none.
- Requires approval: False
- Permission key: none
- Arguments: none
- Example: Use `trigger.list` only when the user intent maps to this manifest tool and all required arguments are known.

### `weather`
- Display name: Current Weather
- Description: Get current weather using GPS or a city. Args: optional location or city. Use when the user asks weather, temperature, rain, snow, wind, forecast now, or conditions.
- Requires approval: False
- Permission key: NSLocationWhenInUseUsageDescription
- Arguments:
  - `location`: string, optional. Inferred from ToolDefinition description Args contract: optional location or city
  - `city`: string, optional. Inferred from ToolDefinition description Args contract: optional location or city
- Example: Use `weather` only when the user intent maps to this manifest tool and all required arguments are known.

### `web.fetch`
- Display name: Fetch URL
- Description: Fetch and read a specific web page. Args: url. Use only when the user gives a URL or a prior web search returns one to inspect.
- Requires approval: False
- Permission key: none
- Arguments:
  - `url`: string, required. Inferred from ToolDefinition description Args contract: url
- Example: Use `web.fetch` only when the user intent maps to this manifest tool and all required arguments are known.

### `web.search`
- Display name: Web Search
- Description: Search the web for general knowledge, fresh information, tutorials, DIY guides, plans, research, articles, or documentation. Args: query. Use this for `search for ...` unless the user explicitly wants nearby/local places.
- Requires approval: False
- Permission key: none
- Arguments:
  - `query`: string, required. Inferred from ToolDefinition description Args contract: query
- Example: Use `web.search` only when the user intent maps to this manifest tool and all required arguments are known.

## UserIntents
- `alarm` → allowed tools: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule, alarm.snooze, alarm.stop
- `calendar` → allowed tools: calendar.create, calendar.list
- `camera` → allowed tools: camera.capture
- `chat` → allowed tools: none
- `contactSearch` → allowed tools: none
- `emailDraft` → allowed tools: none
- `files` → allowed tools: files.read, photos.search, rag.index_files, rag.index_photos, rag.search
- `health` → allowed tools: health.summary
- `maps` → allowed tools: location.current, maps.directions, maps.search
- `memory` → allowed tools: memory.recall, memory.save
- `messageDraft` → allowed tools: none
- `motion` → allowed tools: motion.activity
- `note` → allowed tools: none
- `outlook` → allowed tools: outlook.attachments.list, outlook.draft.create, outlook.folders.list, outlook.mail.send, outlook.message.archive, outlook.message.delete, outlook.message.forward, outlook.message.mark_read, outlook.message.mark_unread, outlook.message.move, outlook.message.read, outlook.message.reply, outlook.message.reply_all, outlook.messages.list, outlook.messages.search, outlook.status
- `phoneCall` → allowed tools: none
- `photos` → allowed tools: files.read, photos.search, rag.index_files, rag.index_photos, rag.search
- `rag` → allowed tools: files.read, photos.search, rag.index_files, rag.index_photos, rag.search
- `reminder` → allowed tools: none
- `trigger` → allowed tools: trigger.cancel, trigger.create, trigger.list
- `unknown` → allowed tools: none
- `weather` → allowed tools: location.current, weather
- `webSearch` → allowed tools: none

## Routing Rules
- `alarm` → allowed: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule, alarm.snooze, alarm.stop; forbidden examples: calendar.create, calendar.list, camera.capture, contacts.search, files.read, health.summary, location.current, mail.draft
- `calendar` → allowed: calendar.create, calendar.list; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `camera` → allowed: camera.capture; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `chat` → allowed: none; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `contactSearch` → allowed: none; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `emailDraft` → allowed: none; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `files` → allowed: files.read, photos.search, rag.index_files, rag.index_photos, rag.search; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `health` → allowed: health.summary; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `maps` → allowed: location.current, maps.directions, maps.search; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `memory` → allowed: memory.recall, memory.save; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `messageDraft` → allowed: none; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `motion` → allowed: motion.activity; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `note` → allowed: none; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `outlook` → allowed: outlook.attachments.list, outlook.draft.create, outlook.folders.list, outlook.mail.send, outlook.message.archive, outlook.message.delete, outlook.message.forward, outlook.message.mark_read, outlook.message.mark_unread, outlook.message.move, outlook.message.read, outlook.message.reply, outlook.message.reply_all, outlook.messages.list, outlook.messages.search, outlook.status; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `phoneCall` → allowed: none; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `photos` → allowed: files.read, photos.search, rag.index_files, rag.index_photos, rag.search; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `rag` → allowed: files.read, photos.search, rag.index_files, rag.index_photos, rag.search; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `reminder` → allowed: none; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `trigger` → allowed: trigger.cancel, trigger.create, trigger.list; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `unknown` → allowed: none; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `weather` → allowed: location.current, weather; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule
- `webSearch` → allowed: none; forbidden examples: alarm.authorization_status, alarm.cancel, alarm.countdown, alarm.list, alarm.pause, alarm.request_authorization, alarm.resume, alarm.schedule

## Memory Scopes
- Scopes: backgroundOnly, conversation, currentTurn, person, preferenceOnly, project, referenceOnly, remCondensed, sourceOfTruth, task, toolObservation, userPreference
- `durable`: durable
- `shortLived`: ttlSeconds=3600
- `timeless`: durable
- `volatile`: ttlSeconds=300

## Permissions
- `alarm.authorization_status`: permission=NSAlarmKitUsageDescription, requiresApproval=False
- `alarm.cancel`: permission=NSAlarmKitUsageDescription, requiresApproval=True
- `alarm.countdown`: permission=NSAlarmKitUsageDescription, requiresApproval=True
- `alarm.list`: permission=NSAlarmKitUsageDescription, requiresApproval=False
- `alarm.pause`: permission=NSAlarmKitUsageDescription, requiresApproval=True
- `alarm.request_authorization`: permission=NSAlarmKitUsageDescription, requiresApproval=True
- `alarm.resume`: permission=NSAlarmKitUsageDescription, requiresApproval=True
- `alarm.schedule`: permission=NSAlarmKitUsageDescription, requiresApproval=True
- `alarm.snooze`: permission=NSAlarmKitUsageDescription, requiresApproval=True
- `alarm.stop`: permission=NSAlarmKitUsageDescription, requiresApproval=True
- `calendar.create`: permission=NSCalendarsFullAccessUsageDescription, requiresApproval=True
- `calendar.list`: permission=NSCalendarsFullAccessUsageDescription, requiresApproval=False
- `camera.capture`: permission=NSCameraUsageDescription, requiresApproval=True
- `contacts.search`: permission=NSContactsUsageDescription, requiresApproval=False
- `health.summary`: permission=NSHealthShareUsageDescription, requiresApproval=False
- `location.current`: permission=NSLocationWhenInUseUsageDescription, requiresApproval=False
- `mail.draft`: permission=none, requiresApproval=True
- `maps.search`: permission=NSLocationWhenInUseUsageDescription, requiresApproval=False
- `messages.draft`: permission=none, requiresApproval=True
- `motion.activity`: permission=NSMotionUsageDescription, requiresApproval=False
- `outlook.draft.create`: permission=none, requiresApproval=True
- `outlook.mail.send`: permission=none, requiresApproval=True
- `outlook.message.archive`: permission=none, requiresApproval=True
- `outlook.message.delete`: permission=none, requiresApproval=True
- `outlook.message.forward`: permission=none, requiresApproval=True
- `outlook.message.mark_read`: permission=none, requiresApproval=True
- `outlook.message.mark_unread`: permission=none, requiresApproval=True
- `outlook.message.move`: permission=none, requiresApproval=True
- `outlook.message.reply`: permission=none, requiresApproval=True
- `outlook.message.reply_all`: permission=none, requiresApproval=True
- `phone.call`: permission=none, requiresApproval=True
- `photos.search`: permission=NSPhotoLibraryUsageDescription, requiresApproval=False
- `rag.index_photos`: permission=NSPhotoLibraryUsageDescription, requiresApproval=False
- `reminders.create`: permission=NSRemindersFullAccessUsageDescription, requiresApproval=True
- `reminders.list`: permission=NSRemindersFullAccessUsageDescription, requiresApproval=False
- `trigger.cancel`: permission=none, requiresApproval=True
- `trigger.create`: permission=none, requiresApproval=True
- `weather`: permission=NSLocationWhenInUseUsageDescription, requiresApproval=False

## Sentinel Policy
- `<hidden_reasoning>` must never appear in user-visible output.
- `<internal_state>` must never appear in user-visible output.
- `<private_reasoning>` must never appear in user-visible output.
- `<scratchpad>` must never appear in user-visible output.
- `<tool_json>` must never appear in user-visible output.
- `<user_final_text>` must never appear in user-visible output.
- `\nAction: \(action.displayContent)\nObservation: \(compactScratchpadObservation(obs.content))` must never appear in user-visible output.
- `\nAction: \(action.displayContent)\nObservation: \(compactScratchpadObservation(result))` must never appear in user-visible output.

## Fleet Topology
- `cortex` calls [embedding, executor, mimicry, mouth, rem] and is called by [rem].
- `embedding` calls [] and is called by [cortex].
- `executor` calls [mouth, rem] and is called by [cortex, rem].
- `mimicry` calls [mouth] and is called by [cortex].
- `mouth` calls [] and is called by [cortex, executor, mimicry].
- `rem` calls [cortex, executor] and is called by [cortex, executor].
- External handoff tools: none
