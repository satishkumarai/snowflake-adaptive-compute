# Contributing

We welcome contributions to improve this Adaptive Compute implementation guide.

## How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-improvement`)
3. Make your changes
4. Test any SQL scripts against a non-production Snowflake account
5. Submit a pull request

## What We're Looking For

- Additional monitoring queries for specific workload patterns
- Performance comparison scripts for niche use cases
- Improved assessment scoring algorithms
- Documentation fixes and clarifications
- Translations

## Guidelines

- All SQL must be tested on Snowflake (not just syntactically valid)
- Include comments explaining the "why" not just the "what"
- Follow existing file naming conventions
- Update the README if adding new scripts or guides

## Code Style

- SQL keywords: UPPERCASE
- Identifiers: UPPER_SNAKE_CASE for objects, lower_snake_case for aliases
- Indent with 4 spaces
- One statement per logical block, separated by blank lines
