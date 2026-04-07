[![REUSE status](https://api.reuse.software/badge/github.com/SAP/cap-llm-plugin)](https://api.reuse.software/info/github.com/SAP/cap-llm-plugin)
[![CI](https://github.com/SAP/cap-llm-plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/SAP/cap-llm-plugin/actions/workflows/ci.yml)
[![Coverage: 97%](https://img.shields.io/badge/coverage-97%25-brightgreen)](./coverage/)

# cap-llm-plugin

## Description

CAP LLM Plugin helps developers create tailored Generative AI based CAP applications by leveraging SAP HANA Cloud Data Anonymization and Vector Engine and SAP AI Core Services. Detailed features:

1. Without exposing confidential data to LLM by anonymizing sensitive data leveraging SAP HANA Cloud Data Anonymization.
2. Seamlessly generate vector embeddings via SAP AI Core.
3. Easily retrieve Chat Completion response via SAP AI Core.
4. Efforlessly perform similarity search via SAP HANA Cloud Vector engine.
5. Simplified single RAG (retrieval-augmented generation) retrieval method powered by SAP AI Core and SAP HANA Cloud Vector Engine.
6. Access the harmonized chat completion API of the SAP AI Core Orchestration service.

## ✔️ Anonymization Features

|                                            **Feature**                                             | **Details**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| :------------------------------------------------------------------------------------------------: | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Seamlessly anonymize sensitive data using a variety of SAP HANA Cloud's anonymization capabilities | Effortlessly anonymize sensitive data within a CAP application by employing a single `@anonymize` annotation using a diverse range of SAP HANA Cloud's anonymization algorithms, including but not limited to: <li> [k-Anonymity](https://help.sap.com/docs/SAP_HANA_PLATFORM/f88e51df089949b2af06ac891c77abf8/205f52e73c4a422e91fb9a0fbd5f3ec6.html)</li><li> [l-Diversity](https://help.sap.com/docs/SAP_HANA_PLATFORM/f88e51df089949b2af06ac891c77abf8/eeb681e53a06434ca8a0fd20ab9c2b7c.html)</li><li> [Differential Privacy](https://help.sap.com/docs/SAP_HANA_PLATFORM/f88e51df089949b2af06ac891c77abf8/ace3f36bad754cc9bbfe2bf473fccf2f.html)</li></ul> |
|     Effortlessly replace the anonymized data within the LLM response with genuine information      | Given that the data provided to the LLM consists of anonymized information, the CAP LLM plugin ensures a seamless replacement of anonymized content within the LLM response with the corresponding authentic data.                                                                                                                                                                                                                                                                                                                                                                                                                                             |

## 🎯 LLM Access Layer Features

|             **Feature**              | **Details**                                                                                                          |
| :----------------------------------: | :------------------------------------------------------------------------------------------------------------------- |
| Embedding generation via SAP AI Core | Easily connect to embedding models via SAP AI Core and generate embeddings seamlessly                                |
|          Similarity search           | Leverage the SAP HANA Cloud's Vector engine to perform similarity search via CAP LLM Plugin                          |
|   Chat LLM Access via SAP AI Core    | Simple access to LLM models via SAP AI Core with simplified method for chat completion                               |
|      Streamlining RAG retrieval      | Single method to streamline the entire RAG retrieval process leveraging SAP AI Core and SAP HANA Cloud Vector Engine |
|    Orchestration Service Support     | Support for SAP AI Core orchestration service's harmonized chat completion APIs                                      |

## Peer Dependencies

This plugin requires the following peer dependencies:

| Package                     | Version   | Purpose                                                                                                           |
| --------------------------- | --------- | ----------------------------------------------------------------------------------------------------------------- |
| `@sap/cds`                  | `>=7.1.1` | SAP Cloud Application Programming Model runtime                                                                   |
| `@sap/cds-hana`             | `>=2`     | SAP HANA Cloud database driver for CDS                                                                            |
| `@sap-ai-sdk/orchestration` | `>=2.0.0` | SAP AI Core Orchestration Service client (required for `getHarmonizedChatCompletion()` and `getContentFilters()`) |

Install them alongside the plugin:

```bash
npm install @sap/cds @sap/cds-hana @sap-ai-sdk/orchestration
```

## Requirements

Please check the samples and documentation:
For API documentation of CAP LLM Plugin, check refer to [SAP Samples](https://github.com/SAP-samples/cap-llm-plugin-samples/tree/main/docs)

For sample use cases leveraging CAP LLM Plugin, refer to [SAP Samples](https://github.com/SAP-samples/cap-llm-plugin-samples).

## ❗ Version Upgrade Notice

From 1.3.\* to 1.4.2 (function signature changed for following methods, version not recommended):  
getEmbedding  
getChatCompletion  
getRagResponse

From 1.3.\* to 1.4.4 and above(backwards compatible, new methods to support more models):  
No change required unless you want to use new methods supporting new models as mentioned in API document:  
(old)getEmbedding -> getEmbeddingWithConfig  
(old)getChatCompletion -> getChatCompletionWithConfig  
(old)getRagResponse -> getRagResponseWithConfig

## Contributing

This project is open to suggestions, bug reports etc. via [GitHub issues](https://github.com/SAP/cap-llm-plugin/issues). For more information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure

If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/SAP/cap-llm-plugin/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone. By participating in this project, you agree to abide by its [Code of Conduct](https://github.com/SAP/.github/blob/main/CODE_OF_CONDUCT.md) at all times.

## Licensing

Copyright 2025 SAP SE or an SAP affiliate company and cap-llm-plugin contributors. Please see our [LICENSE](LICENSE) for copyright and license information. Detailed information including third-party components and their licensing/copyright information is available [via the REUSE tool](https://api.reuse.software/info/github.com/SAP/cap-llm-plugin).
