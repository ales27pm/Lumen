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
}
