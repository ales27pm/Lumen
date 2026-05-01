import Testing
@testable import Lumen

struct IntentRouterTests {

    @Test func weatherHereRoutesToWeatherOnly() async throws {
        let decision = IntentRouter.classify("What is the weather here")
        #expect(decision.intent == .weather)
        #expect(IntentRouter.isToolAllowed("calendar.create", for: decision) == false)
        #expect(IntentRouter.isToolAllowed("web.search", for: decision) == false)
        #expect(IntentRouter.isToolAllowed("weather", for: decision))
    }

    @Test func draftEmailRequiresClarificationWhenUnderspecified() async throws {
        let decision = IntentRouter.classify("Draft a email")
        #expect(decision.intent == .emailDraft)
        #expect(decision.requiresClarification)
        #expect(decision.clarificationPrompt == "Who should I send it to, and what should it say?")
    }

    @Test func webSearchCannotUseCalendarOrReminderTools() async throws {
        let decision = IntentRouter.classify("Search web for diy underground shelter")
        #expect(decision.intent == .webSearch)
        #expect(IntentRouter.isToolAllowed("calendar.create", for: decision) == false)
        #expect(IntentRouter.isToolAllowed("reminders.create", for: decision) == false)
        #expect(IntentRouter.isToolAllowed("web.search", for: decision))
    }

    @Test func calendarPhraseRoutesToCalendarIntent() async throws {
        let decision = IntentRouter.classify("Create an event tomorrow at 5")
        #expect(decision.intent == .calendar)
    }

    @Test func unknownChatDoesNotForceTools() async throws {
        let decision = IntentRouter.classify("How are you today?")
        #expect(decision.intent == .chat || decision.intent == .unknown)
        #expect(decision.allowedToolIDs.isEmpty)
        #expect(!decision.requiresClarification)
    }

    @Test func slotAgentBlocksCalendarActionForWebSearchIntent() async throws {
        let routing = IntentRouter.classify("Search web for diy underground shelter")
        #expect(!SlotAgentService.isActionAllowed("calendar.create", routing: routing))
        #expect(SlotAgentService.isActionAllowed("web.search", routing: routing))
    }

    @Test func explicitChatGreetingRoutesToChatNoTools() async throws {
        let decision = IntentRouter.classify("Hi. How are you")
        #expect(decision.intent == .chat)
        #expect(decision.allowedToolIDs.isEmpty)
        #expect(!IntentRouter.intentRequiresTool(decision))
    }

    @Test func currentLocationPromptsRouteToMapsLocationOnly() async throws {
        let first = IntentRouter.classify("Where are we")
        #expect(first.intent == .maps)
        #expect(first.allowedToolIDs == ["location.current"])
        #expect(IntentRouter.intentRequiresTool(first))
        let second = IntentRouter.classify("Where am I")
        #expect(second.intent == .maps)
        #expect(second.allowedToolIDs == ["location.current"])
        #expect(IntentRouter.intentRequiresTool(second))
    }

    @Test func mailboxReadPromptsRouteToOutlook() async throws {
        for prompt in ["Read new emails", "Check unread emails", "Read the latest email", "Check my unread outlook emails", "Search Outlook for invoices"] {
            let decision = IntentRouter.classify(prompt)
            #expect(decision.intent == .outlook)
            #expect(IntentRouter.intentRequiresTool(decision))
        }
    }

    @Test func emailDraftAndOutlookSendDifferentiation() async throws {
        #expect(IntentRouter.classify("Draft an email to bob@example.com saying hello").intent == .emailDraft)
        #expect(IntentRouter.classify("Send an Outlook email to bob@example.com saying hello").intent == .outlook)
    }
}
