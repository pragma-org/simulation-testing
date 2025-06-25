{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Moskstraumen.Debugger.UserInterface (module Moskstraumen.Debugger.UserInterface) where

import Brick
import Brick.BChan
import Brick.Widgets.Border (borderWithLabel)
import Brick.Widgets.Border.Style (unicode)
import Brick.Widgets.Center (center, vCenter)
import qualified Brick.Widgets.List as L
import Data.Maybe (fromMaybe)
import qualified Data.Text as Text
import Data.Time.LocalTime (LocalTime, TimeZone)
import qualified Data.Vector as Vector
import qualified Graphics.Vty as V
import qualified Graphics.Vty.Platform.Unix as V
import Lens.Micro (Lens', (^.))
import Text.Printf (printf)
import Text.Wrap

import Moskstraumen.Debugger.AnsiEscape (Segment (..), parseANSI)
import Moskstraumen.Debugger.State hiding (
  event,
  from,
  receivedLogical,
  to,
 )
import Moskstraumen.Prelude
import Moskstraumen.Time

------------------------------------------------------------------------

data AppState = AppState
  { _asLog :: L.List () InstanceState
  , _asTimeZone :: TimeZone
  }

asLog :: Lens' AppState (L.List () InstanceState)
asLog f as = (\asLog' -> as {_asLog = asLog'}) <$> f (_asLog as)

mkAppState :: TimeZone -> Vector.Vector InstanceState -> AppState
mkAppState tz values =
  AppState
    { _asLog = L.list () values 1
    , _asTimeZone = tz
    }

updateAppState :: Vector.Vector InstanceState -> AppState -> AppState
updateAppState values' (AppState l0 tz) = AppState (go (length l0) l0) tz
  where
    go :: Int -> L.List () InstanceState -> L.List () InstanceState
    go n l
      | n >= Vector.length values' = l
      | otherwise = go (n + 1) (L.listInsert n (values' Vector.! n) l)

------------------------------------------------------------------------

drawUI :: AppState -> [Widget ()]
drawUI as = [ui]
  where
    ui =
      withBorderStyle unicode
        -- \$ borderWithLabel (str "Debugger")
        $ vBox
          [ hBox
              [ vBox
                  [ borderWithLabel (str "State") $ renderReactorState as
                  , vLimitPercent 33 $ borderWithLabel (str "Events") $ renderEvents as
                  ]
              , borderWithLabel (str "Sequence Diagram") $ renderSeqDia as
              ]
          , vLimit 3
              $ hBox
                [ borderWithLabel (str "Input") $ renderMessage as
                , -- , hLimit 9 $ borderWithLabel (str "Version") $ renderVersion as
                  borderWithLabel (str "Output") $ renderSentMessage as
                ]
          , vLimit 7 $ borderWithLabel (str "Logs") $ renderLogs as
          ]

renderEvent :: LocalTime -> SendEvent -> Text
renderEvent localTime (SendEvent from to event receivedLogical _msg) =
  Text.pack
    $ printf
      "%-25.25s: %-8.8s: %7.7s -> %-7.7s @ %d"
      (show localTime)
      event
      from
      to
      receivedLogical

renderOutputEvent :: SendEvent -> Text
renderOutputEvent (SendEvent _ to _ _ msg) =
  to <> ": " <> msg

renderToText :: AppState -> (InstanceState -> Text) -> Widget ()
renderToText as f =
  center
    $ txtWrapWith
      wrapSettings
      (fromMaybe "?" . fmap (f . snd) $ L.listSelectedElement $ _asLog as)

wrapSettings :: WrapSettings
wrapSettings =
  defaultWrapSettings
    { preserveIndentation = False
    , breakLongWords = True
    }

renderReactorState :: AppState -> Widget ()
renderReactorState as =
  fillWidth
    $ vCenter
    $ myWrap
      ( fromMaybe "?" . fmap (isState . snd) $ L.listSelectedElement $ _asLog as
      )
  where
    fillWidth x = hBox [x, center $ txt " "]
    myWrap = vBox . map myStr . Text.lines
    myStr x =
      hBox
        [ raw $ V.text' a c
        | Segment a c <- parseANSI x
        ]

-- only works for greedy sizes
withHeight :: (Int -> Widget n) -> Widget n
withHeight c =
  Widget
    { hSize = Greedy
    , vSize = Greedy
    , render = do
        ctx <- getContext
        render (c $ ctx ^. availHeightL)
    }

renderSeqDia :: AppState -> Widget ()
renderSeqDia as = withHeight $ \h ->
  fillWidth
    $ vCenter
    $ myWrap
      ( fromMaybe "?"
          . fmap (($ h) . isSeqDia . snd)
          $ L.listSelectedElement
          $ _asLog as
      )
  where
    fillWidth x = hBox [x, center $ str " "]
    myWrap = vBox . map myStr . Text.lines
    myStr x =
      hBox
        [ raw $ V.text' a c
        | Segment a c <- parseANSI x
        ]

renderEvents :: AppState -> Widget ()
renderEvents as =
  center
    $ L.renderList (listDrawElement $ _asTimeZone as) True
    $ _asLog as

renderMessage :: AppState -> Widget ()
renderMessage as = renderToText as (message . isCurrentEvent)

-- renderVersion :: AppState -> Widget ()
-- renderVersion as = renderToText as (show . isRunningVersion)

renderSentMessage :: AppState -> Widget ()
renderSentMessage as =
  renderToText
    as
    (addEmpty . Text.unlines . map renderOutputEvent . isSent)
  where
    addEmpty text
      | Text.null text = "\n"
      | otherwise = text

renderLogs :: AppState -> Widget ()
renderLogs as = renderToText as (addEmpty . Text.unlines . isLogs)
  where
    addEmpty text
      | Text.null text = "\n"
      | otherwise = text

listDrawElement :: TimeZone -> Bool -> InstanceState -> Widget ()
listDrawElement tz sel is =
  let selTxt s =
        if sel
          then withAttr customAttr (txt $ ">" <> s)
          else txt $ " " <> s
  in  selTxt
        $ renderEvent (utcToLocalTime tz (isReceivedTime is))
        $ isCurrentEvent is

------------------------------------------------------------------------

customAttr :: AttrName
customAttr = L.listSelectedAttr <> attrName "custom"

brickApp :: App AppState AppEvent ()
brickApp =
  App
    { appDraw = drawUI
    , appHandleEvent = appEvent
    , appStartEvent = return ()
    , appAttrMap = const theMap
    , appChooseCursor = neverShowCursor
    }

data AppEvent = UpdateState (Vector.Vector InstanceState)

appEvent :: BrickEvent () AppEvent -> EventM () AppState ()
appEvent (VtyEvent e) =
  case e of
    V.EvKey (V.KChar 'q') [] -> halt
    ev -> zoom asLog $ L.handleListEventVi L.handleListEvent ev
appEvent (AppEvent (UpdateState values')) =
  modify (updateAppState values')
appEvent _ = return ()

theMap :: AttrMap
theMap =
  attrMap
    V.defAttr
    [ (customAttr, fg V.cyan)
    ]

runApp :: AppState -> Maybe (BChan AppEvent) -> IO ()
runApp as mBchan = do
  let builder = V.mkVty V.defaultConfig
  initialVty <- builder
  void (customMain initialVty builder mBchan brickApp as)
