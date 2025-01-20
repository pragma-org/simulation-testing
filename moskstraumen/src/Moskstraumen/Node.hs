module Moskstraumen.Node (module Moskstraumen.Node) where

import Control.Monad.Reader
import Control.Monad.State.Strict hiding (state)
import qualified Data.ByteString.Char8 as BS8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Word
import System.IO

import Moskstraumen.Codec
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude

------------------------------------------------------------------------

newtype Node state a = Node {unNode :: ReaderT NodeContext (State (NodeState state)) a}
  deriving newtype
    (Functor, Applicative, Monad, MonadReader NodeContext, MonadState (NodeState state))

data NodeContext = NodeContext
  { sender :: NodeId
  , msgId :: Maybe MessageId
  }

data NodeState state = NodeState
  { nodeId :: NodeId
  , neighbours :: [NodeId]
  , effects :: [Effect]
  , nextMsgId :: Word64
  , state :: state
  , callbacks ::
      Map MessageId ((MessageKind, [(Field, Value)]) -> Node state ())
  }

data Effect = Send Message | Log Text
  deriving (Show)

initialNodeState :: s -> NodeState s
initialNodeState initialState =
  NodeState
    { nodeId = "Uninitialised"
    , neighbours = []
    , effects = []
    , nextMsgId = 0
    , state = initialState
    , callbacks = Map.empty
    }

runNode :: Node s a -> NodeContext -> NodeState s -> (a, NodeState s)
runNode node context state = runState (runReaderT (unNode node) context) state

------------------------------------------------------------------------

info :: Text -> Node s ()
info text =
  modify
    (\nodeState -> nodeState {effects = Log text : nodeState.effects})

setNodeId :: NodeId -> Node s ()
setNodeId self = modify (\nodeState -> nodeState {nodeId = self})

getNodeId :: Node s NodeId
getNodeId = nodeId <$> get

setNeighbours :: [NodeId] -> Node s ()
setNeighbours nodeIds =
  modify (\nodeState -> nodeState {neighbours = nodeIds})

getNeighbours :: Node s [NodeId]
getNeighbours = do
  nodeState <- get
  return nodeState.neighbours

getSender :: Node s NodeId
getSender = sender <$> ask

modifyState :: (state -> state) -> Node state ()
modifyState f = modify (\nodeState -> nodeState {state = f nodeState.state})

getState :: Node state state
getState = state <$> get

sendWithMessageId_ ::
  Maybe MessageId
  -> NodeId
  -> MessageKind
  -> [(Field, Value)]
  -> Node s ()
sendWithMessageId_ mMessageId receiver messageKind fieldValues = do
  nodeState <- get
  let message =
        Message
          { src = nodeState.nodeId
          , dest = receiver
          , body =
              Payload
                { kind = messageKind
                , msgId = mMessageId
                , inReplyTo = Nothing
                , fields = Map.fromList fieldValues
                }
          }
  put nodeState {effects = Send message : nodeState.effects}

send_ :: NodeId -> Payload -> Node s ()
send_ receiver payload = do
  nodeState <- get
  let message =
        Message
          { src = nodeState.nodeId
          , dest = receiver
          , body = payload
          }
  put nodeState {effects = Send message : nodeState.effects}

reply_ :: MessageKind -> [(Field, Value)] -> Node s ()
reply_ messageKind fieldValues = do
  NodeContext { sender = senderNodeId, msgId = requestMessageId } <- ask
  let payload =
        Payload
          { kind = messageKind
          , msgId = requestMessageId
          , inReplyTo = requestMessageId
          , fields = Map.fromList fieldValues
          }
  send_ senderNodeId payload

rpc_ ::
  NodeId
  -> (MessageKind, [(Field, Value)])
  -> ((MessageKind, [(Field, Value)]) -> Node s ())
  -> Node s ()
rpc_ receiver request callback = do
  nodeState <- get
  let msgId' = nodeState.nextMsgId
  put
    nodeState
      { nextMsgId = msgId' + 1
      , callbacks = Map.insert msgId' callback nodeState.callbacks
      }
  uncurry (sendWithMessageId_ (Just msgId') receiver) request

start :: Parser input -> (input -> Node state ()) -> state -> IO ()
start parse node initialState = do
  hPutStrLn stderr "Online"
  loop (initialNodeState initialState)
  where
    loop nodeState = do
      line <- BS8.getLine
      case decode jsonCodec line of
        Left err -> error ("Couldn't decode message: " <> show (err, line))
        Right message -> do
          hPutStrLn stderr ("Incoming message: " <> show message)
          let nodeState' = case lookupCallback message.body.inReplyTo nodeState of
                Nothing -> case runParser parse message of
                  Nothing -> error ("Unknown request: " <> show message)
                  Just input -> do
                    let nodeContext = NodeContext message.src message.body.msgId
                    snd (runNode (node input) nodeContext nodeState)
                Just (inReplyToMessageId, callback) ->
                  let nodeState'' =
                        snd
                          ( runNode
                              (callback (message.body.kind, Map.toList message.body.fields))
                              (NodeContext message.src message.body.msgId)
                              nodeState
                          )
                  in  nodeState''
                        { callbacks = Map.delete inReplyToMessageId nodeState''.callbacks
                        }
          forM_ (reverse nodeState'.effects) $ \effect -> do
            case effect of
              Send message' -> do
                BS8.hPutStr stdout (encode jsonCodec message')
                BS8.hPutStr stdout "\n"
                hFlush stdout
              Log text -> do
                Text.hPutStr stderr text
                Text.hPutStr stderr "\n"
                hFlush stderr
          loop nodeState' {effects = []}

lookupCallback ::
  Maybe MessageId
  -> NodeState state
  -> Maybe (MessageId, ((MessageKind, [(Field, Value)]) -> Node state ()))
lookupCallback Nothing _nodeState = Nothing
lookupCallback (Just inReplyToMessageId) nodeState =
  case Map.lookup inReplyToMessageId nodeState.callbacks of
    Nothing -> Nothing
    Just callback -> Just (inReplyToMessageId, callback)
