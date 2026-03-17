# RobUIHeal Changelog

## Version 0.1

Initial public repository setup.

Core systems and project structure prepared for open development.

---

Future updates and patch notes will be documented here.

## v13

### Improvements


### Fixes
Silver fixed minimap postion saving.

## v15

Fixed raid click-healing by changing raid frames to a stable unit-token model. Each frame is now permanently bound to a fixed raid unit (raid1 to raid40), while sorting only changes visual position. This prevents secure click-cast overlays from drifting to the wrong unit when raid layout updates. Also fixed raid layout so it works correctly in both real raid and sim/settings mode, including entries without a unit token.
