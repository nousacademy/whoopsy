# Whoop Algorithm Investigator Skill

## Purpose
Instantly investigate, deconstruct, and analyze open-source approximations of wearable health-analytics metrics (Recovery, Strain, Sleep stages, HRV RMSSD baselines, and physiological CSV schemas) whenever the user inquires about a Whoop algorithm, calculation method, or metric implementation.

## Trigger Conditions
This skill automatically activates whenever the user:
- Asks how Whoop calculates a specific metric (e.g., "How does Whoop calculate recovery scores?", "What's the math behind day strain?").
- References open-source repos, reverse-engineered protocol specs, or data parsing logic for health metrics.
- Asks to inspect, compare, or build algorithms related to physiological data processing.

## Execution Protocol
Upon activation:
1. **Search & Retrieve:** Perform targeted web searches for top-rated GitHub repositories, open-source parsers (such as `whoop-reader`, `OpenStrap/edge`, or community data tools), and physiological whitepapers.
2. **Deconstruct the Math:** Break down the underlying mathematics (e.g., RMSSD extraction, rolling 30-day baselines, exponential strain curves).
3. **Translate to Swift:** Provide clear, type-safe Swift implementations or Clean Architecture patterns that map cleanly to local health metric models without cloud dependencies.dd