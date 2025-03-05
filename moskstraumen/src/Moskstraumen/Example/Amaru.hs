module Moskstraumen.Example.Amaru (module Moskstraumen.Example.Amaru) where

import Data.Aeson
import Data.Aeson.Types
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Text as Text
import Data.Tree
import Debug.Trace

import Moskstraumen.Prelude
import Paths_moskstraumen

------------------------------------------------------------------------

type Chain = Tree Block

data Block = Block
  { hash :: Text
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

t :: IO ()
t = do
  bs <- readChainJson
  case parseJson bs of
    Nothing -> putStrLn "parseJson failed"
    Just blocks -> putStr $ drawTree $ fmap summary $ recreateTree blocks

summary :: Block -> String
summary block =
  unlines
    [ "{ parent = " <> maybe "null" (Text.unpack . Text.take 8) block.parent
    , ", hash = " <> Text.unpack (Text.take 8 block.hash)
    , ", height = "
        <> show block.height
    , "}"
    ]
