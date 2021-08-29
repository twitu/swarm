{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

module Swarm.TUI where

import           Control.Concurrent.STM      (atomically)
import           Control.Concurrent.STM.TVar
import           Control.Lens
import           Control.Monad               (when)
import           Control.Monad.IO.Class      (liftIO)
import           Data.Array                  (range)
import           Data.Either                 (isRight)
import           Data.List.Split             (chunksOf)
import           Data.Map                    (Map)
import qualified Data.Map                    as M
import           Data.Maybe                  (isJust)
import           Data.Text                   (Text)
import           Linear
import           Witch                       (into)

import           Brick                       hiding (Direction)
import           Brick.Focus
import           Brick.Forms
import           Brick.Widgets.Center        (center, hCenter)
import           Brick.Widgets.Dialog
import qualified Graphics.Vty                as V

import           Brick.Widgets.Border        (hBorder)
import           Control.Arrow               ((&&&))
import           Swarm.Game
import qualified Swarm.Game.World            as W
import           Swarm.Language.Pipeline
import           Swarm.Language.Syntax       (east, north, south, west)
import           Swarm.TUI.Attr
import           Swarm.TUI.Panel
import           Swarm.Util

------------------------------------------------------------
-- Custom UI label types

data Tick = Tick

data Name
  = REPLPanel
  | WorldPanel
  | InfoPanel
  | REPLInput
  | WorldCache
  | WorldExtent
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

------------------------------------------------------------
-- UI state

data REPLHistItem = REPLEntry Text | REPLOutput Text
  deriving (Eq, Ord, Show)

data UIState = UIState
  { _uiFocusRing      :: FocusRing Name
  , _uiReplForm       :: Form Text Tick Name
  , _uiReplHistory    :: [REPLHistItem]
  , _uiReplHistIdx    :: Int
  , _uiError          :: Maybe (Widget Name)
  , _needsLoad        :: Bool
  , _lgTicksPerSecond :: TVar Int
  }

makeLenses ''UIState

initFocusRing :: FocusRing Name
initFocusRing = focusRing [REPLPanel, InfoPanel, WorldPanel]

replPrompt :: Text
replPrompt = "> "

initReplForm :: Form Text Tick Name
initReplForm = newForm
  [(txt replPrompt <+>) @@= editTextField id REPLInput (Just 1)]
  ""

initLgTicksPerSecond :: Int
initLgTicksPerSecond = 3    -- 2^3 = 8 ticks per second

initUIState :: IO UIState
initUIState = do
  tv <- newTVarIO initLgTicksPerSecond
  return $ UIState initFocusRing initReplForm [] (-1) Nothing True tv

------------------------------------------------------------
-- App state (= UI state + game state)

data AppState = AppState
  { _gameState :: GameState
  , _uiState   :: UIState
  }

makeLenses ''AppState

initAppState :: IO AppState
initAppState = AppState <$> initGameState <*> initUIState

------------------------------------------------------------
-- UI drawing

drawUI :: AppState -> [Widget Name]
drawUI s =
  [ drawDialog (s ^. uiState)
  , joinBorders $
    vBox
    [ hBox
      [ panel highlightAttr fr InfoPanel $ drawInfoPanel s
      , panel highlightAttr fr WorldPanel $ hLimitPercent 75 $ drawWorld (s ^. gameState)
      ]
    , panel highlightAttr fr REPLPanel $ vLimit replHeight $ padBottom Max $ padLeftRight 1 $ drawRepl s
    ]
  ]
  where
    fr = s ^. uiState . uiFocusRing

replHeight :: Int
replHeight = 10

errorDialog :: Dialog ()
errorDialog = dialog (Just "Error") Nothing 80

drawDialog :: UIState -> Widget Name
drawDialog s = case s ^. uiError of
  Nothing -> emptyWidget
  Just d  -> renderDialog errorDialog d

drawWorld :: GameState -> Widget Name
drawWorld g
  = center
  $ cached WorldCache
  $ reportExtent WorldExtent
  $ Widget Fixed Fixed $ do
    ctx <- getContext
    let w   = ctx ^. availWidthL
        h   = ctx ^. availHeightL
        ixs = range (viewingRegion g (w,h))
    render . vBox . map hBox . chunksOf w . map drawLoc $ ixs
  where
    robotsByLoc
      = M.fromListWith (maxOn (^. robotDisplay . priority)) . map (view location &&& id)
      . M.elems $ g ^. robotMap
    drawLoc (row,col) = case M.lookup (V2 row col) robotsByLoc of
      Just r  -> withAttr (r ^. robotDisplay . robotDisplayAttr)
                 $ str [lookupRobotDisplay (r ^. direction) (r ^. robotDisplay)]
      Nothing -> drawResource (W.lookup (row,col) (g ^. world))

drawInfoPanel :: AppState -> Widget Name
drawInfoPanel s
  = vBox
    [ drawInventory (s ^. gameState . inventory)
    , hBorder
    , vLimitPercent 30 $ padBottom Max $ drawMessages (s ^. gameState . messageQueue)
    ]

drawMessages :: [Text] -> Widget Name
drawMessages [] = txt " "
drawMessages ms = Widget Fixed Fixed $ do
  ctx <- getContext
  let h   = ctx ^. availHeightL
  render . vBox . map txt . reverse . take h $ ms

drawInventory :: Map Item Int -> Widget Name
drawInventory inv
  = padBottom Max
  $ vBox
  [ hCenter (str "Inventory")
  , padAll 2
    $ vBox
    $ map drawItem (M.assocs inv)
  ]

drawItem :: (Item, Int) -> Widget Name
drawItem (Resource c, n) = drawNamedResource c <+> showCount n
  where
    showCount = padLeft Max . str . show

drawNamedResource :: Char -> Widget Name
drawNamedResource c = case M.lookup c resourceMap of
  Nothing -> str [c]
  Just rInfo ->
    hBox [ withAttr (rInfo ^. resAttr) (padRight (Pad 2) (str [c])), txt (rInfo ^. resName) ]

drawResource :: Char -> Widget Name
drawResource c = case M.lookup c resourceMap of
  Nothing    -> str [c]
  Just rInfo -> withAttr (rInfo ^. resAttr) (str [c])

drawRepl :: AppState -> Widget Name
drawRepl s = vBox $
  map fmt (reverse (take (replHeight - 1) (s ^. uiState . uiReplHistory)))
  ++
  case isActive <$> (s ^. gameState . robotMap . at "base") of
    Just False -> [ renderForm (s ^. uiState . uiReplForm) ]
    _          -> [ padRight Max $ txt "..." ]
  where
    fmt (REPLEntry e)  = txt replPrompt <+> txt e
    fmt (REPLOutput t) = txt t

------------------------------------------------------------
-- Event handling

handleEvent :: AppState -> BrickEvent Name Tick -> EventM Name (Next AppState)
handleEvent s (AppEvent Tick)                        = do
  let g = s ^. gameState
  g' <- liftIO $ gameStep g
  when (g' ^. updated) $ invalidateCacheEntry WorldCache

  let s' = s & gameState .~ g'
             & case g' ^. replResult of
                 { Just (_, Just VUnit) ->
                     gameState . replResult .~ Nothing
                 ; Just (_ty, Just v) ->
                     (uiState . uiReplHistory %~ (REPLOutput (into (prettyValue v)) :)) .
                     (gameState . replResult .~ Nothing)
                 ; _ -> id
                 }

  s'' <- case s' ^. uiState . needsLoad of
    False -> return s'
    True  -> do
      mext <- lookupExtent WorldExtent
      case mext of
        Nothing -> return s'
        Just _  -> return $ s' & uiState . needsLoad .~ False

  continue s''

handleEvent s (VtyEvent (V.EvResize _ _))            = do
  invalidateCacheEntry WorldCache
  continue $ s & uiState . needsLoad .~ True
handleEvent s (VtyEvent (V.EvKey (V.KChar '\t') [])) = continue $ s & uiState . uiFocusRing %~ focusNext
handleEvent s (VtyEvent (V.EvKey V.KBackTab []))     = continue $ s & uiState . uiFocusRing %~ focusPrev
handleEvent s (VtyEvent (V.EvKey V.KEsc []))
  | isJust (s ^. uiState . uiError) = continue $ s & uiState . uiError .~ Nothing
  | otherwise                       = halt s
handleEvent s ev =
  case focusGetCurrent (s ^. uiState . uiFocusRing) of
    Just REPLPanel  -> handleREPLEvent s ev
    Just WorldPanel -> handleWorldEvent s ev
    _               -> continueWithoutRedraw s

handleREPLEvent :: AppState -> BrickEvent Name Tick -> EventM Name (Next AppState)
handleREPLEvent s (VtyEvent (V.EvKey (V.KChar 'c') [V.MCtrl]))
  = continue $ s
      & gameState . robotMap . ix "base" . machine .~ idleMachine
handleREPLEvent s (VtyEvent (V.EvKey V.KEnter []))
  = case processTerm entry of
      Right (t ::: ty) ->
        continue $ s
          & uiState . uiReplForm    %~ updateFormState ""
          & uiState . uiReplHistory %~ (REPLEntry entry :)
          & uiState . uiReplHistIdx .~ (-1)
          & gameState . replResult ?~ (ty, Nothing)
          & gameState . robotMap . ix "base" . machine .~ initMachine t ty
      Left err ->
        continue $ s
          & uiState . uiError ?~ txt err
  where
    entry = formState (s ^. uiState . uiReplForm)
handleREPLEvent s (VtyEvent (V.EvKey V.KUp []))
  = continue $ s & uiState %~ adjReplHistIndex (+)
handleREPLEvent s (VtyEvent (V.EvKey V.KDown []))
  = continue $ s & uiState %~ adjReplHistIndex (-)
handleREPLEvent s ev = do
  f' <- handleFormEvent ev (s ^. uiState . uiReplForm)
  let result = processTerm (formState f')
      f''    = setFieldValid (isRight result) REPLInput f'
  continue $ s & uiState . uiReplForm .~ f''

adjReplHistIndex :: (Int -> Int -> Int) -> UIState -> UIState
adjReplHistIndex (+/-) s =
  s & uiReplHistIdx .~ newIndex
    & if newIndex /= curIndex then uiReplForm %~ updateFormState newEntry else id
  where
    entries = [e | REPLEntry e <- s ^. uiReplHistory]
    curIndex = s ^. uiReplHistIdx
    histLen  = length entries
    newIndex = min (histLen - 1) (max (-1) (curIndex +/- 1))
    newEntry
      | newIndex == -1 = ""
      | otherwise      = entries !! newIndex

worldScrollDist :: Int
worldScrollDist = 8

handleWorldEvent :: AppState -> BrickEvent Name Tick -> EventM Name (Next AppState)
handleWorldEvent s (VtyEvent (V.EvKey k []))
  | k `elem` [V.KUp, V.KDown, V.KLeft, V.KRight]
  = scrollView s (^+^ (worldScrollDist *^ keyToDir k)) >>= continue
handleWorldEvent s (VtyEvent (V.EvKey (V.KChar '<') []))
  = adjustTPS (-) s >> continueWithoutRedraw s
handleWorldEvent s (VtyEvent (V.EvKey (V.KChar '>') []))
  = adjustTPS (+) s >> continueWithoutRedraw s

-- Fall-through case: don't do anything.
handleWorldEvent s _ = continueWithoutRedraw s

scrollView :: AppState -> (V2 Int -> V2 Int) -> EventM Name AppState
scrollView s update =
  updateView $ s & gameState %~ manualViewCenterUpdate update

updateView :: AppState -> EventM Name AppState
updateView s = do
  invalidateCacheEntry WorldCache
  mext <- lookupExtent WorldExtent
  case mext of
    Nothing  -> return s
    Just (Extent _ _ size) -> return $
      s & gameState . world %~ W.loadRegion (viewingRegion (s ^. gameState) size)

keyToDir :: V.Key -> V2 Int
keyToDir V.KUp    = north
keyToDir V.KDown  = south
keyToDir V.KRight = east
keyToDir V.KLeft  = west
keyToDir _        = V2 0 0

viewingRegion :: GameState -> (Int,Int) -> ((Int, Int), (Int, Int))
viewingRegion g (w,h) = ((rmin,cmin), (rmax,cmax))
  where
    V2 cr cc = g ^. viewCenter
    (rmin,rmax) = over both (+ (cr - h`div`2)) (0, h-1)
    (cmin,cmax) = over both (+ (cc - w`div`2)) (0, w-1)

adjustTPS :: (Int -> Int -> Int) -> AppState -> EventM Name ()
adjustTPS (+/-) s =
  liftIO $ atomically $ modifyTVar (s ^. uiState . lgTicksPerSecond) (+/- 1)
