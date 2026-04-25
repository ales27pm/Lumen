import Spezi
import SpeziLLM
import SpeziLLMLocal

class LumenAppDelegate: SpeziAppDelegate {
    override var configuration: Configuration {
        Configuration {
            LLMRunner {
                LLMLocalPlatform()
            }
        }
    }
}
