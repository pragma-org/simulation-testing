module Moskstraumen.Example.Amaru (module Moskstraumen.Example.Amaru) where

import Data.Aeson (FromJSON, decode, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map as Map
import Data.Monoid (Alt (Alt), getAlt)
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Tree
import Debug.Trace

import Moskstraumen.Generate
import Moskstraumen.Message
import Moskstraumen.NodeId
import Moskstraumen.Prelude
import Moskstraumen.Random
import Moskstraumen.Simulate
import Moskstraumen.Workload
import Paths_moskstraumen

------------------------------------------------------------------------

type Chain = Tree Block

type Hash = Text

data Block = Block
  { hash :: Hash
  , header :: Text
  , height :: Int
  , parent :: Maybe Text
  , slot :: Int
  }
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON)

------------------------------------------------------------------------

readChainJson :: IO ByteString
readChainJson = do
  filePath <- getDataFileName "chain.json"
  LBS.readFile filePath

parseJson :: ByteString -> Maybe [Block]
parseJson bytes = do
  result <- decode bytes
  flip parseMaybe result $ \obj -> do
    stakePools <- obj .: "stakePools"
    stakePools .: "chains"

------------------------------------------------------------------------

recreateTree :: [Block] -> Chain
recreateTree [] = error "recreateTree: empty"
recreateTree (block0 : blocks0) = case block0.parent of
  Nothing -> Node block0 (go block0.hash blocks0)
  Just _ -> error "recreateTree: first block has a parent"
  where
    go :: Text -> [Block] -> [Chain]
    go _parentHash [] = []
    go parentHash blocks =
      let siblings = takeWhile (\block -> block.parent == Just parentHash) blocks
          blocks' = drop (length siblings) blocks
      in  map (\block -> Node block (go block.hash blocks')) siblings

------------------------------------------------------------------------

data Input
  = Fwd {hash :: Hash, slot :: Int, header :: Text}
  | Bck {hash :: Hash, slot :: Int}
  | Topology {upsteam :: [Text], downstream :: [Text]}
  deriving stock (Show)

defaultTopology :: Input
defaultTopology = Topology ["c1"] []

generateInputs :: Chain -> Gen [Input]
generateInputs chain0 = go [] chain0 [] Set.empty
  where
    go :: [Input] -> Chain -> [GenStep] -> Set Hash -> Gen [Input]
    go acc (Node block []) [] _done = return (reverse (Fwd block.hash block.slot block.header : acc))
    go acc (Node block []) steps@(Fork parentHash parentSlot _indices : _) done
      -- XXX: This won't work for other chains, obviously...
      | block.height == 47 = do
          return (reverse (Fwd block.hash block.slot block.header : acc))
      | otherwise = do
          go
            ( Bck parentHash parentSlot : Fwd block.hash block.slot block.header : acc
            )
            (findNodeInTree_ (\block' -> block'.hash == parentHash) chain0)
            steps
            done
    go acc (Node block [child]) steps done = go (Fwd block.hash block.slot block.header : acc) child steps done
    go acc (Node block children) [] done
      | block.hash `Set.member` done = do
          return (reverse acc)
      | otherwise = do
          index <- chooseInt (0, length children - 1)
          go
            (Fwd block.hash block.slot block.header : acc)
            (children !! index)
            (Fork block.hash block.slot [index] : [])
            done
    go acc node@(Node block children) (Fork hash _slot indices : steps) done
      | block.hash == hash && length children /= length indices = do
          index <-
            chooseInt (0, length children - 1) `suchThat` (`notElem` indices)
          go
            acc
            (children !! index)
            (Fork hash _slot (index : indices) : steps)
            done
      | block.hash == hash && length children == length indices = do
          go acc node steps (Set.insert hash done)
      | otherwise = do
          index <- chooseInt (0, length children - 1)
          go
            (Fwd block.hash block.slot block.header : acc)
            (children !! index)
            (Fork block.hash block.slot [index] : steps)
            done

data GenStep = Fork Hash Int [Int]
  deriving stock (Show)

inputsToMessages :: [Input] -> [Message]
inputsToMessages = go 0 []
  where
    go _n acc [] = reverse acc
    go n acc (input : inputs) =
      let (inputKind, fields_) = case input of
            Fwd hash slot header ->
              ( "fwd"
              , [("hash", String hash), ("slot", Int slot), ("header", String header)]
              )
            Bck hash slot -> ("bck", [("hash", String hash), ("slot", Int slot)])
            Topology upstream downstream ->
              ( "topology"
              ,
                [ ("upstream", List (map String upstream))
                , ("downstream", List (map String downstream))
                ]
              )
      in  go
            (n + 1)
            ( Message
                { src = "c1"
                , dest = "n1"
                , body =
                    Payload
                      { kind = inputKind
                      , msgId = Just n
                      , inReplyTo = Nothing
                      , fields = Map.fromList fields_
                      }
                }
                : acc
            )
            inputs

------------------------------------------------------------------------

t :: IO ()
t = do
  bs <- readChainJson
  case parseJson bs of
    Nothing -> putStrLn "parseJson failed"
    Just blocks -> do
      -- seed <- randomIO
      let seed = 123
      let prng = mkPrng seed
          size = 30
      mapM_ print
        $ snd
        $ runGen (generateInputs (recreateTree blocks)) prng size

chainTree :: IO Text
chainTree = do
  bs <- readChainJson
  case parseJson bs of
    Nothing -> error "parseJson failed"
    Just blocks ->
      return
        ( "Block tree:\n"
            <> ( Text.pack
                  ( drawTree
                      ( fmap
                          summary
                          (recreateTree blocks)
                      )
                  )
               )
        )

s :: IO ()
s = do
  text <- chainTree
  Text.putStr text

debugLastBlock :: IO ()
debugLastBlock = do
  bs <- readChainJson
  case parseJson bs of
    Nothing -> putStrLn "parseJson failed"
    Just blocks -> print (last blocks)

ss :: IO ()
ss = do
  bs <- readChainJson
  -- seed <- randomIO
  let seed = 1234
  let prng = mkPrng seed
      size = 30
  case parseJson bs of
    Nothing -> putStrLn "parseJson failed"
    Just blocks -> do
      let messages =
            snd
              $ runGen
                (fmap inputsToMessages (generateInputs (recreateTree blocks)))
                prng
                size
      putStrLn "messages: "
      mapM_
        ( \message ->
            print
              ( message.body.kind
              , message.body.fields Map.! "hash"
              , message.body.fields Map.! "slot"
              )
        )
        messages
      putStrLn
        $ "fwds: "
        ++ show
          ( length
              ( filter
                  ( \message -> case message.body.kind of
                      "fwd" -> True
                      _otherwise -> False
                  )
                  messages
              )
          )

      putStrLn
        $ "bcks: "
        ++ show
          ( length
              ( filter
                  ( \message -> case message.body.kind of
                      "bck" -> True
                      _otherwise -> False
                  )
                  messages
              )
          )

      putStrLn ("length messages: " ++ show (length messages))
      putStrLn ("length blocks: " ++ show (length blocks))
      putStrLn ("heights: " ++ show (map height blocks))

summary :: Block -> String
summary block =
  unlines
    -- [ "{ parent = " <> maybe "null" (Text.unpack . Text.take 8) block.parent
    [ "{ hash = " <> Text.unpack (Text.take 8 block.hash)
    , ", height = " <> show block.height
    , "}"
    ]

------------------------------------------------------------------------

findNodeInTree_ :: (a -> Bool) -> Tree a -> Tree a
findNodeInTree_ p tree = case findNodeInTree p tree of
  Nothing -> error "findNodeInTree_: elem not in tree"
  Just tree' -> tree'

findNodeInTree :: (a -> Bool) -> Tree a -> Maybe (Tree a)
findNodeInTree p tree@(Node {rootLabel, subForest})
  | p rootLabel = Just tree
  | otherwise = findNodeInForest p subForest

findNodeInForest ::
  (Foldable t) => (a -> Bool) -> t (Tree a) -> Maybe (Tree a)
findNodeInForest p forest =
  getAlt (foldMap (Alt . findNodeInTree p) forest)

------------------------------------------------------------------------

amaruWorkload :: IO Workload
amaruWorkload = do
  bs <- readChainJson
  case parseJson bs of
    Nothing -> error "workload: parseJson failed"
    Just blocks ->
      return
        Workload
          { name = "Amaru workload"
          , generate = fmap inputsToMessages (generateInputs (recreateTree blocks))
          , property = TracePredicate (tracePredicate (last blocks))
          , prettyFailure =
              Just
                $ ( chainTree
                  , \message ->
                      unNodeId message.src
                        <> " -- "
                        <> unMessageKind message.body.kind
                        <> " --> "
                        <> unNodeId message.dest
                        <> if message.body.kind == "fwd" || message.body.kind == "bck"
                          then
                            " { hash: "
                              <> prettyHash (message.body.fields Map.! "hash")
                              <> ", slot: "
                              <> prettySlot (message.body.fields Map.! "slot")
                              <> "}"
                          else ""
                  )
          }
  where
    prettyHash (String hash) = Text.take 8 hash <> "..."
    prettyHash _ = error "prettyHash"

    prettySlot (Int slot) = textShow slot
    prettySlot _ = error "prettySlot"

    tracePredicate :: Block -> [Message] -> PropertyResult
    tracePredicate lastBlock messages =
      let lastMessageSUT = last messages
          lastHashSUT = lastMessageSUT.body.fields Map.! "hash"
      in  lastHashSUT === String lastBlock.hash

------------------------------------------------------------------------

libMain :: [String] -> IO ()
libMain args = do
  case args of
    [binaryFilePath] ->
      print =<< blackboxTest binaryFilePath =<< amaruWorkload
    _otherwise -> error "pass path to binary as argument"
