import Speech
import Testing
@testable import AirTranslate

struct AppleSpeechModuleTests {
    @Test func explicitRussianCanUseDictationWhenSpeechTranscriberDoesNotSupportIt() async throws {
        let russian = LanguageOption.russian
        guard await SpeechTranscriber.supportedLocale(equivalentTo: russian.locale) == nil,
              await DictationTranscriber.supportedLocale(equivalentTo: russian.locale) != nil else { return }

        let module = try #require(await LiveSpeechTranscriber.makeModule(for: russian))
        #expect(module.transcriber is DictationTranscriber)
        #expect(await LiveSpeechTranscriber.makeModule(for: russian, allowsRussianDictation: false) == nil)
        let availability = await ModelAvailabilityChecker.availability(source: russian, target: .english)
        #expect(availability[IntelligenceModel.appleSpeechOnly.id]?.state != .unsupported)
    }

    @Test func englishStillUsesSpeechTranscriber() async throws {
        guard SpeechTranscriber.isAvailable,
              await SpeechTranscriber.supportedLocale(equivalentTo: LanguageOption.english.locale) != nil else { return }

        let module = try #require(await LiveSpeechTranscriber.makeModule(for: .english))
        #expect(module.transcriber is SpeechTranscriber)
    }
}
