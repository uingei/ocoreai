// Copyright © 2026 uingei@163.com.
// Licensed under MIT.
/// ModelIdentityTests — Parse coverage + prefixedId correctness.
///
/// ModelIdentity is the single source of truth for Hub routing.
/// If parse or prefixedId is wrong, models download from the wrong Hub.

import Testing
@testable import ocoreai

@Suite("ModelIdentity — parse and prefixedId")
struct ModelIdentityTests {

	// MARK: - mscope: prefix

	@Test("mscope: prefix routes to ModelScope")
	func mscopePrefixRoute() {
		let id = ModelIdentity.parse("mscope:Qwen/Qwen2.5-7B-Instruct")
		#expect(id.source == .modelScope(repoId: "Qwen/Qwen2.5-7B-Instruct"))
		#expect(id.prefixedId == "mscope:Qwen/Qwen2.5-7B-Instruct")
		#expect(id.repoId == "Qwen/Qwen2.5-7B-Instruct")
	}

	// MARK: - hf: prefix

	@Test("hf: prefix routes to HuggingFace")
	func hfPrefixRoute() {
		let id = ModelIdentity.parse("hf:mlx-community/Qwen3.5-4B")
		#expect(id.source == .huggingFace(repoId: "mlx-community/Qwen3.5-4B"))
		#expect(id.prefixedId == "hf:mlx-community/Qwen3.5-4B")
		#expect(id.repoId == "mlx-community/Qwen3.5-4B")
	}

	// MARK: - huggingface: prefix

	@Test("huggingface: prefix routes to HuggingFace")
	func huggingfacePrefixRoute() {
		let id = ModelIdentity.parse("huggingface:org/model-name")
		#expect(id.source == .huggingFace(repoId: "org/model-name"))
		#expect(id.prefixedId == "hf:org/model-name")
		#expect(id.repoId == "org/model-name")
	}

	// MARK: - Bare org/repo

	@Test("bare org/repo defaults to HuggingFace without hub override")
	func bareOrgRepoDefaultsToHF() {
		let id = ModelIdentity.parse("mlx-community/Llama-3.1-8B")
		#expect(id.source == .huggingFace(repoId: "mlx-community/Llama-3.1-8B"))
		#expect(id.prefixedId == "hf:mlx-community/Llama-3.1-8B")
	}

	@Test("bare org/repo with ModelScope hub override routes to ModelScope")
	func bareOrgRepoModelScopeOverride() {
		let id = ModelIdentity.parse("Qwen/Qwen2.5-7B", hub: .modelScope)
		#expect(id.source == .modelScope(repoId: "Qwen/Qwen2.5-7B"))
		#expect(id.prefixedId == "mscope:Qwen/Qwen2.5-7B")
	}

	@Test("bare org/repo with HuggingFace hub override routes to HF")
	func bareOrgRepoHFOVERRIDE() {
		let id = ModelIdentity.parse("org/model", hub: .huggingFace)
		#expect(id.source == .huggingFace(repoId: "org/model"))
		#expect(id.prefixedId == "hf:org/model")
	}

	// MARK: - Local paths

	@Test("absolute path routes to local")
	func absolutePathToLocal() {
		let id = ModelIdentity.parse("/path/to/model")
		#expect(id.source == .local(path: "/path/to/model"))
		#expect(id.prefixedId == "/path/to/model")
		#expect(id.repoId == "/path/to/model")
	}

	@Test("tilde path routes to local")
	func tildePathToLocal() {
		let id = ModelIdentity.parse("~/models/my-model")
		#expect(id.source == .local(path: "~/models/my-model"))
		#expect(id.prefixedId == "~/models/my-model")
	}

	@Test("single component falls back to local")
	func singleComponentToLocal() {
		let id = ModelIdentity.parse("some-model-name")
		#expect(id.source == .local(path: "some-model-name"))
	}

	// MARK: - PrefixedId carries hub prefix for EnginePool routing

	@Test("prefixedId carries hf: for HuggingFace source")
	func prefixedIdHasHF() {
		let id = ModelIdentity.huggingFace("org/repo")
		#expect(id.prefixedId == "hf:org/repo")
	}

	@Test("prefixedId carries mscope: for ModelScope source")
	func prefixedIdHasMScope() {
		let id = ModelIdentity.modelScope("org/repo")
		#expect(id.prefixedId == "mscope:org/repo")
	}

	@Test("prefixedId is bare for local source")
	func prefixedIdBareForLocal() {
		let id = ModelIdentity.local("/path/to/model")
		#expect(id.prefixedId == "/path/to/model")
	}

	// MARK: - Factory methods

	@Test("factory creates correct identity")
	func factoryMethods() {
		let hf = ModelIdentity.huggingFace("org/model")
		#expect(hf.source == .huggingFace(repoId: "org/model"))

		let ms = ModelIdentity.modelScope("org/model")
		#expect(ms.source == .modelScope(repoId: "org/model"))

		let loc = ModelIdentity.local("/path")
		#expect(loc.source == .local(path: "/path"))
	}

	// MARK: - hubSource conversion

	@Test("hubSource maps correctly")
	func hubSourceMapping() {
		#expect(ModelIdentity.huggingFace("x/y").hubSource == .huggingFace)
		#expect(ModelIdentity.modelScope("x/y").hubSource == .modelScope)
		#expect(ModelIdentity.local("/x").hubSource == .huggingFace)
	}

	// MARK: - progressKey extension

	@Test("progressKey strips mscope: prefix")
	func progressKeyStripsMScope() {
		#expect(("mscope:org/repo").progressKey == "org/repo")
	}

	@Test("progressKey strips hf: prefix")
	func progressKeyStripsHF() {
		#expect(("hf:org/repo").progressKey == "org/repo")
	}

	@Test("progressKey strips huggingface: prefix")
	func progressKeyStripsHuggingFace() {
		#expect(("huggingface:org/repo").progressKey == "org/repo")
	}

	@Test("progressKey returns bare string unchanged")
	func progressKeyBareUnchanged() {
		#expect(("org/repo").progressKey == "org/repo")
	}
}
