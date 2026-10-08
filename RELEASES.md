# Core package release preparation

Agentif and LLMProviders currently identify as 1.0.0 but have no registered
General releases. Their package subdirectories include the monorepo MIT
license so source archives retain the licensing terms.

To replace downstream Git revisions with registered versions:

1. Release and register JSONSchema 1.6. Both core packages use its schema
   generation API and require `JSONSchema = "1.6"`.
2. Run the LLMProviders tests against that registered JSONSchema release,
   then register the `LLMProviders` subdirectory at the reviewed commit.
3. Run Agentif's suite against the registered LLMProviders and JSONSchema
   releases, then register the `Agentif` subdirectory at the reviewed commit.
4. Check General's install/load validation and monorepo URL review, then
   confirm the release tags and update downstream lockfiles.

The development projects retain their `[sources]` entries while the first
registrations are pending. Package metadata and local tests do not establish
that these registration or publication steps have completed.

Optional LLMOAuth and LocalSearch extensions remain separate release work;
Agentif can load without those weak dependencies.
