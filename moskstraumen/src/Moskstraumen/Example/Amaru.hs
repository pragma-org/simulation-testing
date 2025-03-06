module Moskstraumen.Example.Amaru (module Moskstraumen.Example.Amaru) where

import Data.Aeson
import Data.Aeson.Types
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid (Alt (Alt), getAlt)
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Tree
import Debug.Trace
import System.Random

import Moskstraumen.Generate
import Moskstraumen.Prelude
import Moskstraumen.Random
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

data Input = Fwd Hash | Bwd Hash
  deriving stock (Show)

generate :: Chain -> Gen [Input]
generate chain0 = go [] chain0 [] Set.empty
  where
    go :: [Input] -> Chain -> [GenStep] -> Set Hash -> Gen [Input]
    go acc (Node block []) [] _done = return (reverse (Fwd block.hash : acc))
    go acc (Node block []) steps@(Fork parentHash _indices : _) done =
      go
        (Bwd parentHash : acc)
        (findNodeInTree_ (\block -> block.hash == parentHash) chain0)
        steps
        done
    go acc (Node block [child]) steps done = go (Fwd block.hash : acc) child steps done
    go acc (Node block children) [] done
      | block.hash `Set.member` done = do
          return (reverse acc)
      | otherwise = do
          index <- chooseInt (0, length children - 1)
          go
            (Fwd block.hash : acc)
            (children !! index)
            (Fork block.hash [index] : [])
            done
    go acc node@(Node block children) (Fork hash indices : steps) done
      | block.hash == hash && length children /= length indices = do
          index <-
            chooseInt (0, length children - 1) `suchThat` (`notElem` indices)
          go acc (children !! index) (Fork hash (index : indices) : steps) done
      | block.hash == hash && length children == length indices = do
          go acc node steps (Set.insert hash done)
      | otherwise = do
          index <- chooseInt (0, length children - 1)
          go
            (Fwd block.hash : acc)
            (children !! index)
            (Fork block.hash [index] : steps)
            done

data GenStep = Fork Hash [Int]
  deriving stock (Show)

------------------------------------------------------------------------

t :: IO ()
t = do
  bs <- readChainJson
  case parseJson bs of
    Nothing -> putStrLn "parseJson failed"
    Just blocks -> do
      seed <- randomIO
      let prng = mkPrng seed
          size = 30
      mapM_ print $ snd $ runGen (generate (recreateTree blocks)) prng size

-- Just blocks -> putStr $ drawTree $ fmap summary $ recreateTree blocks

summary :: Block -> String
summary block =
  unlines
    [ "{ parent = " <> maybe "null" (Text.unpack . Text.take 8) block.parent
    , ", hash = " <> Text.unpack (Text.take 8 block.hash)
    , ", height = "
        <> show block.height
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
