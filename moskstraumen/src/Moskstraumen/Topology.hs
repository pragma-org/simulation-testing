module Moskstraumen.Topology (module Moskstraumen.Topology) where

import Data.List ((\\))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Tree

import Moskstraumen.NodeId
import Moskstraumen.Prelude

------------------------------------------------------------------------

-- | Arrange nodes in a square grid topology, such that each node has at most four neighbours.
gridTopology :: [NodeId] -> Map NodeId [NodeId]
gridTopology nodes =
  Map.fromList
    [ ( n
      , concat
          [ node (i + 1) j
          , node (i - 1) j
          , node i (j + 1)
          , node i (j - 1)
          ]
      )
    | i <- [0 .. side - 1]
    , j <- [0 .. side - 1]
    , n <- node i j
    ]
  where
    len :: Int
    len = length nodes

    side :: Int
    side = ceiling (sqrt (fromIntegral len))

    node :: Int -> Int -> [NodeId]
    node i j
      | 0 <= idx && idx < len = [nodes !! idx]
      | otherwise = []
      where
        idx :: Int
        idx = i * side + j

totalTopology :: [NodeId] -> Map NodeId [NodeId]
totalTopology nodes = Map.fromList [(node, nodes \\ [node]) | node <- nodes]

-- XXX: Hardcoded to 5 nodes and b = 4.
-- Arranges nodes into a tree with branch factor b.
treeTopology :: Int -> [NodeId] -> Map NodeId [NodeId]
treeTopology 4 [_, _, _, _, _] =
  Map.fromList
    [ (makeNodeId 1, [makeNodeId 2, makeNodeId 3, makeNodeId 4, makeNodeId 5])
    , (makeNodeId 2, [makeNodeId 1])
    , (makeNodeId 3, [makeNodeId 1])
    , (makeNodeId 4, [makeNodeId 1])
    , (makeNodeId 5, [makeNodeId 1])
    ]
treeTopology _ _ = error "treeTopology: not implemented yet"
