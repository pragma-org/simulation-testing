module Moskstraumen.Example.KeyValueStore (module Moskstraumen.Example.KeyValueStore) where

import qualified Data.Aeson as Json
import Data.ByteString.Lazy (LazyByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text

import Moskstraumen.Codec
import Moskstraumen.EventLoop2
import Moskstraumen.Message
import Moskstraumen.Node4
import Moskstraumen.NodeId
import Moskstraumen.Parse
import Moskstraumen.Prelude

------------------------------------------------------------------------

data Input
  = Init {node_id :: NodeId, node_ids :: [NodeId]}
  | Txn {txn :: [MicroOp]}
  | Read {key :: Text}
  | Cas
      { key :: Text
      , from :: Text
      , to :: Text
      , create_if_not_exists :: Bool
      }

data MicroOp
  = R Key [Int]
  | Append Key Int
  deriving (Show)

type Key = Int

data Output
  = InitOk
  | TxnOk {txn :: [MicroOp]}
  | ReadOk {value :: State}
  | CasOk
  | Error {code :: Int, text :: Text}

type State = IntMap [Int]

initialState :: State
initialState = IntMap.empty

keyValueStore :: Input -> Node State Input Output
keyValueStore (Init myNodeId myNeighbours) = do
  info ("Initialising: " <> unNodeId myNodeId)
  setNodeId myNodeId
  setPeers myNeighbours
  reply InitOk
keyValueStore (Txn ops) = do
  store <- getState
  let (store', ops') = transact ops store
  putState store'
  reply (TxnOk ops')

transact :: [MicroOp] -> State -> (State, [MicroOp])
transact = go []
  where
    go acc [] store = (store, reverse acc)
    go acc (op : ops') store = case op of
      R key [] ->
        go
          (R key (concat (maybeToList (IntMap.lookup key store))) : acc)
          ops'
          store
      R _key (_ : _) -> error "keyValueStore: client read contains values"
      Append key value ->
        go
          (Append key value : acc)
          ops'
          (IntMap.insertWith (\new old -> old <> new) key [value] store)

kEY :: Text
kEY = "root"

keyValueStoreV2 :: Input -> Node () Input Output
keyValueStoreV2 (Init myNodeId myNeighbours) = do
  info ("Initialising: " <> unNodeId myNodeId)
  setNodeId myNodeId
  setPeers myNeighbours
  reply InitOk
keyValueStoreV2 (Txn ops) = do
  sender <- getSender
  info
    $ "Got txn from: "
    <> unNodeId sender
    <> " "
    <> fromString (show ops)
  readResponse <- syncRpc "lin-kv" (Read kEY) (info "sync rpc failed...")
  store <- case readResponse of
    Error code text -> do
      info
        ("Read failed, code: " <> Text.pack (show code) <> ", text: " <> text)
      return initialState
    ReadOk store -> do
      info $ "Successful read: " <> fromString (show store)
      return store
  let (store', ops') = transact ops store
  info $ "attempting CAS " <> toJson store <> " " <> toJson store'
  casResponse <-
    syncRpc
      "lin-kv"
      (Cas kEY (toJson store) (toJson store') True)
      (info "sync rpc failed...")
  case casResponse of
    Error code text -> do
      info
        ("CAS failed, code: " <> Text.pack (show code) <> ", text: " <> text)
      reply
        (Error code text)
    CasOk -> info "CAS successful!"

  sender <- getSender
  info $ "replying to sender: " <> unNodeId sender
  reply (TxnOk ops')

------------------------------------------------------------------------

toJson :: State -> Text
toJson = Text.decodeUtf8 . LBS.toStrict . Json.encode

validateInput_ :: Parser Input
validateInput_ =
  asum
    [ Init
        <$ hasKind "init"
        <*> hasNodeIdField "node_id"
        <*> hasListField "node_ids" isNodeId
    , Txn
        <$ hasKind "txn"
        <*> hasListField "txn" validateMicroOp
    ]

validateMicroOp :: Value -> Maybe MicroOp
validateMicroOp (List [String "r", Int k, List []]) = Just ((R k) [])
validateMicroOp (List [String "append", Int k, Int v]) = Just (Append k v)
validateMicroOp _ = Nothing

marshalInput_ :: Input -> (MessageKind, [(Field, Value)])
marshalInput_ (Init _myNodeId _myNeighbours) = ("init", [])
marshalInput_ (Txn _ops) = ("txn", [])
marshalInput_ (Read key) = ("read", [("key", String key)])
marshalInput_ (Cas key old new create) =
  ( "cas"
  ,
    [ ("key", String key)
    , ("from", String old)
    , ("to", String new)
    , ("create_if_not_exists", Bool create)
    ]
  )

marshalOutput_ :: Output -> (MessageKind, [(Field, Value)])
marshalOutput_ InitOk = ("init_ok", [])
marshalOutput_ (TxnOk ops) = ("txn_ok", [("txn", List (map marshalMicroOp ops))])
marshalOutput_ (Error code text) = ("error", [("code", Int code), ("text", String text)])

marshalMicroOp :: MicroOp -> Value
marshalMicroOp (R key values) = List [String "r", Int key, List (map Int values)]
marshalMicroOp (Append key value) = List [String "append", Int key, Int value]

validateOutput_ :: Parser Output
validateOutput_ =
  asum
    [ InitOk <$ hasKind "init_ok"
    , TxnOk <$ hasKind "txn_ok" <*> pure [] -- XXX: not used...
    , ReadOk
        <$ hasKind "read_ok"
        <*> ( ( \text ->
                  either (\err -> error (show (text, err))) id
                    . (Json.eitherDecode :: LazyByteString -> Either String State)
                    . LBS.fromStrict
                    . Text.encodeUtf8
                    $ text
              )
                <$> hasTextField "value"
            )
    , CasOk <$ hasKind "cas_ok"
    , Error
        <$ hasKind "error"
        <*> hasField "code" isInt
        <*> hasField "text" isText
    ]

------------------------------------------------------------------------

libMain :: IO ()
libMain =
  consoleEventLoop
    keyValueStoreV2
    ()
    ValidateMarshal
      { validateInput = validateInput_
      , validateOutput = validateOutput_
      , marshalInput = marshalInput_
      , marshalOutput = marshalOutput_
      }
