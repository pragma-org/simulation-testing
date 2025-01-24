module Moskstraumen.EventLoop (module Moskstraumen.EventLoop) where

import Moskstraumen.Prelude
import Moskstraumen.Runtime

------------------------------------------------------------------------

eventLoop_ ::
  (Monad m) =>
  (Event -> state -> (state, [Effect]))
  -> state
  -> Runtime m
  -> m ()
eventLoop_ handleEvent initialState runtime =
  loop initialState
  where
    loop nodeState = do
      event <- runtime.source
      if event == ExitEvent
        then return ()
        else do
          let (nodeState', effects) = handleEvent event nodeState
          mapM_ runtime.sink effects
          loop nodeState'
