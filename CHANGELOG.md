# Changelog

## v3.0.4

- Fixed raid and party frame heal prediction colors rendering wrong (e.g. red appearing black, yellow appearing green) instead of the color set in settings.
- Fixed color changes made through the color picker not saving if the settings panel wasn't explicitly confirmed before a UI reload.
- Added manual R/G/B number entry to the color picker, in addition to the color wheel.
- Clarified in the color swatch tooltips that the "overheal warning" colors only apply when the overheal threshold setting is enabled, and swap the whole bar rather than just the overhealing portion.

## v3.0.3

- Fixed the color picker in settings not saving color changes.
- Added tooltips to the color swatches in settings explaining what each color controls.

## v3.0.2

- Nameplate heal prediction is now off by default. Enabling it can trigger a Blizzard client bug (a UI "taint" error) introduced by nameplate changes in Classic Era patch 1.15.9 - not a bug in heal prediction itself. Opt in via the options panel if you want it; see the checkbox's tooltip for details.
- Fixed the nameplate option not saving correctly when changed.

## v3.0.0

- Initial release of YetAnotherHealPrediction, rebranded from HealPredictionClassic and updated for WoW Classic Era patch 1.15.9.
