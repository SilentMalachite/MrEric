# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2025-11-19

### Added
- 🎉 Initial release of MrEric
- ✨ Phoenix LiveView-based AI agent interface
- 🤖 OpenAI API integration with full model support
  - GPT-4o (default)
  - GPT-4o Mini
  - GPT-4 Turbo
  - GPT-4
  - GPT-3.5 Turbo
  - O1 Preview
  - O1 Mini
- 🎨 GUI for model selection with dropdown
- ⚡ Real-time streaming responses from OpenAI
- 📝 Task execution history with timestamps
- 💾 In-memory storage using ETS
- 🎯 High-level API for task execution
- 🔧 Configurable default model in config files
- 🧪 Comprehensive test suite
  - Unit tests for OpenAI client
  - Integration tests for LiveView
  - Mocking with Mox
- 📚 Complete documentation
  - README with setup and usage guide
  - API reference documentation
  - Inline code documentation
- 🎨 Modern UI with Tailwind CSS v4
  - Hero Icons integration
  - Responsive design
  - Loading states with animations
  - Clean card-based layout
- 🚀 Performance optimizations
  - Bandit HTTP server
  - Req HTTP client
  - Stream-based responses
- 🔒 Security best practices
  - Environment variable for API keys
  - No database (stateless by design)
  - Clean separation of concerns

### Technical Details
- **Framework**: Phoenix 1.8 + LiveView 1.1
- **Language**: Elixir 1.17
- **HTTP Server**: Bandit
- **HTTP Client**: Req
- **CSS**: Tailwind CSS v4
- **Icons**: Hero Icons
- **Testing**: ExUnit + Mox
- **AI**: OpenAI API

### Configuration
- Default model: `gpt-4o`
- Port: `4000` (configurable)
- No database required

### Known Limitations
- Task history is stored in memory (cleared on restart)
- No authentication system
- Single-user design
- No conversation context management

### Future Considerations
- [ ] Persistent storage option (optional)
- [ ] Multi-user support
- [ ] Conversation history with context
- [ ] Additional AI providers (Anthropic, etc.)
- [ ] File upload support
- [ ] Code execution environment
- [ ] Streaming improvements
- [ ] Advanced error handling

## Development Process

### Initial Setup (2025-11-19)
1. Created Phoenix application with LiveView
2. Removed Ecto and database dependencies
3. Integrated OpenAI API client
4. Implemented streaming responses
5. Built task execution engine
6. Created in-memory storage with ETS

### UI Development (2025-11-19)
1. Created basic LiveView interface
2. Added model selection dropdown
3. Implemented real-time streaming display
4. Designed execution history view
5. Applied modern styling with Tailwind CSS
6. Added loading states and animations

### Testing & Quality (2025-11-19)
1. Wrote unit tests for core modules
2. Created LiveView integration tests
3. Set up Mox for API mocking
4. Configured precommit checks
5. Ensured test coverage

### Documentation (2025-11-19)
1. Created comprehensive README
2. Wrote API documentation
3. Added inline code documentation
4. Created this CHANGELOG

## Contributors

- **SilentMalachite** - Initial work and development

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

[Unreleased]: https://github.com/SilentMalachite/MrEric/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/SilentMalachite/MrEric/releases/tag/v0.1.0
