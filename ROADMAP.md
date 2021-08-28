- Make commands return useful things
    - View should return boolean?
[
- Add 'def' form, similar to let but without 'in' part, for top-level definitions
- Mechanism for importing definitions from another file
- Lib dir with standard code to load
- Special seed robots to make harvested things regrow
- Make world not writeable
]
- Add colors
    - New type of colors and color constants
    - Command to let a robot change its color
    - Command to let a robot change its appearance?
- Add a version of turn that allows turning to any vector
- Refactor
    - Swarm.Language.{Types, AST -> Syntax, Parse, Typecheck,
      Elaborate, Pipeline}
    - Swarm.Game.*
    - Swarm.{UI -> TUI.*}.*
- Implement craftable items.
- Refactor
    - All V2 Int values should be x,y.  Only convert to row,column in
      the UI.
    - Start by making a newtype for V2 Int, then fix all the type
      errors and think carefully about it.
    - Fix Turn values, e.g. north, south etc.
- Program some "mobs", i.e. cats =D
    - Make a command to sense the ID of a nearby robot
    - Make a command to pick up another robot by ID
- Give each robot its own inventory.  Add commands for giving/receiving.
- Some resources, e.g. rocks, block robots.
- Pause button and single-stepping.
- Add UI feature to look up robots by ID.
    - See their currently executing program?
- Restrict programs based on installed devices etc.
- Update world implementations with newtypes to represent indices.
- Implement world zooming.
- Improve handling of ticks.
- Allow smaller, finite worlds?
- Built-in program/function editor?
- Create world with biomes etc. using multiple noise sources
- Add type annotations to the language.
- Fix pretty-printing
  - Print operators infix
  - Better indentation/layout etc.
- Redo using a fast effects library?