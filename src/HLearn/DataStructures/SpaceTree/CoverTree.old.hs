{-# LANGUAGE NoMonomorphismRestriction,DataKinds,PolyKinds,MagicHash,UnboxedTuples,TemplateHaskell #-}

module HLearn.DataStructures.CoverTree
    ({- CoverTree
    , -}CoverTree'

    , insertBatch
    , trainMonoid
    , trainInsert

    -- * unsafe
--     , ctmap
--     , unsafeMap
--     , recover
--     , trainct_insert
    , sortChildren
    , cmp_numdp_distance
    , cmp_numdp_distance'
    , cmp_distance_numdp
    , cmp_distance_numdp'

    , packCT
    , packCT2
    , packCT3

    , setMaxDescendentDistance

    -- * drawing
--     , draw
--     , draw'
--     , IntShow (..)

    -- * QuickCheck properties
    , property_separating
    , property_covering
    , property_leveled
    , property_maxDescendentDistance
    )
    where

import GHC.TypeLits
import Control.Monad
import Control.Monad.Random hiding (fromList)
import Control.Monad.ST
import Control.DeepSeq
import qualified Data.List
import Data.List (null,take,sortBy,mapAccumL,filter,zip,concatMap,drop)
import Data.List (and,or)
import Data.Maybe
-- import Data.Monoid hiding ((+))
-- import Data.Semigroup
import Data.Primitive hiding (Array)
import Data.Proxy
import qualified Data.Foldable as F
import qualified Data.Set as Set
import qualified Data.Strict.Maybe as Strict
import qualified Data.Strict.Tuple as Strict
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as VM
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Generic.Mutable as VGM
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Unboxed.Mutable as VUM
import qualified Data.Vector.Primitive as VP
import qualified Data.Vector.Primitive.Mutable as VPM

import Test.QuickCheck
import Debug.Trace

-- import Diagrams.Prelude hiding (distance,trace,query,connect)
-- import Diagrams.Backend.SVG.CmdLine
-- import Diagrams.Backend.Postscript.CmdLine

-- import qualified Control.ConstraintKinds as CK
-- import HLearn.Algebra hiding ((+),(|>),numdp, Frac(..), fracVal, KnownFrac )
-- import qualified HLearn.Algebra
import SubHask hiding (toList,fromList)
import SubHask.Algebra.Vector

import Prelude (map,head,tail,length)
import HLearn.DataStructures.SpaceTree
-- import HLearn.DataStructures.SpaceTree.DualTreeMonoids
-- import HLearn.DataStructures.SpaceTree.Algorithms.NearestNeighbor hiding (weight)
-- import HLearn.DataStructures.SpaceTree.Algorithms.RangeSearch
-- import qualified HLearn.DataStructures.StrictList as Strict
-- import HLearn.DataStructures.StrictList (List (..))

import HLearn.UnsafeVector
import HLearn.Models.Classifiers.Common
import HLearn.Metrics.Lebesgue

import Data.Params

deriving instance NFData (v r) => NFData (Array v r)

-------------------------------------------------------------------------------
-- data types

-- type CoverTree dp = AddUnit (CoverTree' (Static (2/1)) V.Vector V.Vector) () dp

data CoverTree'
        ( expansionRatio       :: {-Config-} Frac )
        ( childContainer        :: * -> * )
        ( nodeContainer         :: * -> * )
        ( tag                   :: * )
        ( dp                    :: * )
    = Node
        { nodedp                :: {-#UNPACK#-}!(L2 VU.Vector Float)
        , level                 :: {-#UNPACK#-}!Int
--         , weight                :: {-#UNPACK#-}!Float
        , numdp                 :: {-#UNPACK#-}!Float
        , maxDescendentDistance :: {-#UNPACK#-}!Float
        , children              :: {-#UNPACK#-}!(Array V.Vector (CoverTree' expansionRatio childContainer VU.Vector tag dp))
        , nodeV                 :: {-#UNPACK#-}!(Array VU.Vector (L2 VU.Vector Float))
--         , tag                   :: !tag
        }

-- mkParams ''CoverTree'

{-# INLINE weight #-}
weight :: CoverTree' expansionRatio childContainer nodeContainer tag dp -> Float
weight _ = 1

---------------------------------------
-- standard instances

-- deriving instance
--     ( Read (Scalar dp)
--     , Read (childContainer (CoverTree' expansionRatio childContainer nodeContainer tag dp))
--     , Read (nodeContainer dp)
--     , Read tag
--     , Read dp
--     , ValidCT expansionRatio childContainer nodeContainer tag dp
--     ) => Read (CoverTree' expansionRatio childContainer nodeContainer tag dp)

-- deriving instance
--     ( Show (Scalar dp)
--     , Show (childContainer (CoverTree' expansionRatio childContainer nodeContainer tag dp))
--     , Show (nodeContainer dp)
--     , Show tag
--     , Show dp
--     , ValidCT expansionRatio childContainer nodeContainer tag dp
--     ) => Show (CoverTree' expansionRatio childContainer nodeContainer tag dp)

instance
    ( NFData dp
    , NFData (Scalar dp)
    , NFData tag
    , ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => NFData (CoverTree' expansionRatio childContainer nodeContainer tag dp)
        where
    rnf ct = rnf $ _children ct
--     rnf ct = deepseq (numdp ct)
--            $ deepseq (maxDescendentDistance ct)
--            $ seq ct
--            $ ()

---------------------------------------
-- non-standard instances
--
class
    ( MetricSpace dp
    , Ord (Scalar dp)
    , Floating (Scalar dp)
    , Monoid tag
    , Monoid (nodeContainer dp)
    , Monoid (childContainer dp)
    , Monoid (childContainer (CoverTree' expansionRatio childContainer nodeContainer tag dp))
    , FromList nodeContainer dp
    , FromList childContainer dp
    , FromList childContainer (Scalar dp)
    , FromList childContainer (CoverTree' expansionRatio childContainer nodeContainer tag dp)
    , KnownFrac expansionRatio
--     , ViewParam Param_expansionRatio (CoverTree' expansionRatio childContainer nodeContainer tag dp)
    , Show (Scalar dp)
    , Show dp
    , Ord dp
    , VU.Unbox dp
    , nodeContainer ~ Array VU.Vector
--     , Prim dp
--     , nodeContainer ~ VP.Vector
    , childContainer ~ Array V.Vector
    , VG.Vector nodeContainer dp
    , VG.Vector childContainer (CoverTree' expansionRatio childContainer nodeContainer tag dp)
    , dp ~ L2 VU.Vector Float
    ) => ValidCT expansionRatio childContainer nodeContainer tag dp

instance
    ( MetricSpace dp
    , Ord (Scalar dp)
    , Floating (Scalar dp)
    , Monoid tag
    , Monoid (nodeContainer dp)
    , Monoid (childContainer dp)
    , Monoid (childContainer (CoverTree' expansionRatio childContainer nodeContainer tag dp))
    , FromList nodeContainer dp
    , FromList childContainer dp
    , FromList childContainer (Scalar dp)
    , FromList childContainer (CoverTree' expansionRatio childContainer nodeContainer tag dp)
    , KnownFrac expansionRatio
    , Show (Scalar dp)
    , Show dp
    , Ord dp
    , VU.Unbox dp
    , nodeContainer ~ Array VU.Vector
--     , Prim dp
--     , nodeContainer ~ VP.Vector
    , childContainer ~ Array V.Vector
    , VG.Vector nodeContainer dp
    , VG.Vector childContainer (CoverTree' expansionRatio childContainer nodeContainer tag dp)
    , dp ~ L2 VU.Vector Float
    ) => ValidCT expansionRatio childContainer nodeContainer tag dp

type instance Scalar (CoverTree' expansionRatio childContainer nodeContainer tag dp) = Scalar dp

instance
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => SpaceTree (CoverTree' expansionRatio childContainer nodeContainer tag) dp
        where

    type NodeContainer (CoverTree' expansionRatio childContainer nodeContainer tag) = nodeContainer
    type ChildContainer (CoverTree' expansionRatio childContainer nodeContainer tag) = childContainer

    {-# INLINABLE stMinDistance #-}
    {-# INLINABLE stMaxDistance #-}

    stMinDistanceWithDistance !ct1 !ct2 =
        (# dist-(maxDescendentDistance ct1)-(maxDescendentDistance ct2), dist #)
        where dist = distance (nodedp ct1) (nodedp ct2)

    stMaxDistanceWithDistance !ct1 !ct2 =
        (# dist+(maxDescendentDistance ct1)+(maxDescendentDistance ct2), dist #)
        where dist = distance (nodedp ct1) (nodedp ct2)

    {-# INLINABLE stMinDistanceDpWithDistance #-}
    {-# INLINABLE stMaxDistanceDpWithDistance #-}

    stMinDistanceDpWithDistance !ct !dp =
        (# dist - maxDescendentDistance ct, dist #)
        where dist = distance (nodedp ct) dp

    stMaxDistanceDpWithDistance !ct !dp =
        (# dist + maxDescendentDistance ct, dist #)
        where dist = distance (nodedp ct) dp

--     {-# INLINABLE stMinDistanceDpFromDistance #-}
--     {-# INLINABLE stMaxDistanceDpFromDistance #-}
--     stIsMinDistanceDpFartherThanWithDistance !ct !dp !b =
--         case isFartherThanWithDistance (nodedp ct) dp (b+maxDescendentDistance ct) of
--             Strict.Nothing -> Strict.Nothing
--             Strict.Just dist -> Strict.Just $ dist
--
--     stIsMaxDistanceDpFartherThanWithDistance !ct !dp !b =
--         isFartherThanWithDistance (nodedp ct) dp (b-maxDescendentDistance ct)

    {-# INLINABLE stIsMinDistanceDpFartherThanWithDistanceCanError #-}
    {-# INLINABLE stIsMaxDistanceDpFartherThanWithDistanceCanError #-}

    stIsMinDistanceDpFartherThanWithDistanceCanError !ct !dp !b =
        isFartherThanWithDistanceCanError (nodedp ct) dp (b+maxDescendentDistance ct)

    stIsMaxDistanceDpFartherThanWithDistanceCanError !ct !dp !b =
        isFartherThanWithDistanceCanError (nodedp ct) dp (b-maxDescendentDistance ct)

    {-# INLINABLE stIsMinDistanceDpFartherThanWithDistance #-}
    {-# INLINABLE stIsMaxDistanceDpFartherThanWithDistance #-}

    stMinDistanceDpFromDistance !ct !dp !dist = dist-maxDescendentDistance ct
    stMaxDistanceDpFromDistance !ct !dp !dist = dist+maxDescendentDistance ct

    {-# INLINE stChildren #-}
    {-# INLINE stNode #-}
    {-# INLINE stNodeV #-}
    {-# INLINE stHasNode #-}
    {-# INLINE stIsLeaf #-}
    stChildren  = children
    stNodeV     = nodeV
    stNode      = nodedp
    stWeight    = weight
    stHasNode _ = True
    stIsLeaf ct = null $ toList $ children ct

    {-# INLINE ro #-}
    ro _ = 0

    {-# INLINE lambda #-}
    lambda !ct = maxDescendentDistance ct

-------------------------------------------------------------------------------
--

setMaxDescendentDistance ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
setMaxDescendentDistance ct = ct
    { children = children'
    , maxDescendentDistance = max
        ( maximum $ 0 : ( VG.toList $ VG.map maxDescendentDistance children' ) )
        ( maximum $ 0 : ( VG.toList $ VG.map (distance $ nodedp ct) $ nodeV ct ) )
    }
    where
        children' = VG.map setMaxDescendentDistance $ children ct

---------------------------------------

sortChildren ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => ( CoverTree' expansionRatio childContainer nodeContainer tag dp
        -> CoverTree' expansionRatio childContainer nodeContainer tag dp
        -> CoverTree' expansionRatio childContainer nodeContainer tag dp
        -> Ordering
         )
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
sortChildren cmp ct = ct
-- sortChildren cmp ct = ct
--     { children = fromList $ sortBy (cmp ct) $ map (sortChildren cmp) $ toList $ children ct
--     }
--     FIXME: commented all this out just for compiling with subhask

instance Semigroup Ordering where
    LT+_=LT
    GT+_=GT
    EQ+x=x

-- cmp_numdp_distance ct a b
--     = compare
--         (numdp a)
--         (numdp b)
--     + compare
--         (distance (nodedp ct) (nodedp a))
--         (distance (nodedp ct) (nodedp b))
--
-- cmp_numdp_distance' ct b a
--     = compare
--         (numdp a)
--         (numdp b)
--     + compare
--         (distance (nodedp ct) (nodedp a))
--         (distance (nodedp ct) (nodedp b))
--
-- cmp_distance_numdp ct a b
--     = compare
--         (distance (nodedp ct) (nodedp a))
--         (distance (nodedp ct) (nodedp b))
--     + compare
--         (numdp a)
--         (numdp b)
--
-- cmp_distance_numdp' ct b a
--     = compare
--         (distance (nodedp ct) (nodedp a))
--         (distance (nodedp ct) (nodedp b))
--     + compare
--         (numdp a)
--         (numdp b)

-------------------------------------------------------------------------------

packCT ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    , VG.Vector nodeContainer dp
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
packCT ct = sndHask $ go 0 ct'
    where
        go i t = (i',t
            { nodedp = v VG.! i
            , nodeV = VG.slice (i+1) (VG.length $ nodeV t) v
            , children = fromList children'
            })
            where
                (i',children') = mapAccumL
                    go
                    (i+1+length (toList $ nodeV t))
                    (toList $ children t)

        ct' = setNodeV 0 ct
        v = fromList $ mkNodeList ct'

        mkNodeList ct = [nodedp ct]
                     ++ (toList $ nodeV ct)
                     ++ (concatMap mkNodeList $ toList $ children ct)


setNodeV ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => Int
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
setNodeV n ct = if stNumNodes ct > n
    then ct
        { children = fromList $ fmap (setNodeV n) $ filter (not . stIsLeaf) $ toList $ children ct
        , nodeV = fromList $ fmap nodedp $ filter stIsLeaf $ toList $ children ct
        }
    else ct
        { children = zero
        , nodeV = fromList $ stToList ct
        }

packCT3 ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    , VG.Vector nodeContainer dp
    , VUM.Unbox dp
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
packCT3 ct = sndHask $ go 0 ct
    where
        go i t = (i',t
            { nodedp = v VU.! i
            , children = fromList children'
            })
            where
                (i',children') = mapAccumL go (i+1) (toList $ children t)

        v = fromList $ mkNodeList ct

        mkNodeList ct = [nodedp ct]
                     ++ (concatMap mkNodeList $ toList $ children ct)

packCT2 ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    , VG.Vector nodeContainer dp
    , VUM.Unbox dp
    ) => Int
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
packCT2 n ct = sndHask $ go 1 $ ct' { nodedp = v VG.! 0 }
    where
        go i t = (i',t
            { nodeV = VG.slice i (VG.length $ nodeV t) v
            , children = fromList children'
            })
            where
                (i',children') = mapAccumL go
                    (i+length (toList $ nodeV t)+length (toList $ children t))
                    (fmap (\(j,x) -> if nodedp x /= v VG.! j then error ("/="++show j) else x { nodedp = v VG.! j } )
                        $ zip [i+length (toList $ nodeV t) .. ] $ toList $ children t)

        ct' = setNodeV n ct
        v = fromList $ mkNodeList ct'

        mkNodeList ct = [nodedp ct]++go_mkNodeList ct
        go_mkNodeList ct = (toList $ nodeV ct)
                        ++ (map nodedp $ toList $ children ct)
                        ++ (concatMap go_mkNodeList $ toList $ children ct)

-------------------------------------------------------------------------------
-- insertion as described in the paper

safeInsert :: forall expansionRatio childContainer nodeContainer tag dp.
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> Weighted# dp
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
safeInsert node (# 0,_  #) = {-# SCC safeInsert0 #-} node
safeInsert node (# w,dp #) = {-# SCC safeInsertw #-} case insert node (# w,dp #) of
    Strict.Just x -> x
    Strict.Nothing -> Node
        { nodedp    = dp
        , level     = dist2level_up (Proxy::Proxy expansionRatio) dist
--         , weight    = w
        , numdp     = numdp node+1
        , children  = if stIsLeaf node
            then fromList [node { level = dist2level_down (Proxy::Proxy expansionRatio) dist } ]
            else fromList [node]
        , nodeV     = zero
        , maxDescendentDistance = maximum $ map (distance dp) $ stToList node
--         , tag       = zero
        }
        where
            dist = distance (nodedp node) dp

insert :: forall expansionRatio childContainer nodeContainer tag dp.
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> Weighted# dp
      -> Strict.Maybe (CoverTree' expansionRatio childContainer nodeContainer tag dp)
insert node (# w,dp #) = {-# SCC insert #-} if isFartherThan dp (nodedp node) (sepdist node)
    then Strict.Nothing
    else Strict.Just $ Node
        { nodedp    = nodedp node
        , level     = level node
--         , weight    = weight node
        , numdp     = weight node + sum (map numdp children')
        , children  = fromList $ {-sortBy sortgo-} children'
        , nodeV     = zero
        , maxDescendentDistance = max
            (maxDescendentDistance node)
            (distance (nodedp node) dp)
--         , tag       = tag node
        }

    where
--         sortgo ct1 ct2 = compare
--             (distance dp (nodedp ct1))
--             (distance dp (nodedp ct2))
--         sortgo ct1 ct2 = compare
--             (distance (nodedp node) (nodedp ct2))
--             (distance (nodedp node) (nodedp ct1))

--         children' = go $ sortBy sortgo $ toList $ children node
        children' = {-# SCC children' #-} go $ toList $ children node

        go [] = {-# SCC go_base #-}[ Node
                    { nodedp   = dp
                    , level    = level node-1
--                     , weight   = w
                    , numdp    = w
                    , children = zero
                    , nodeV    = zero
                    , maxDescendentDistance = 0
--                     , tag      = zero
                    }
                ]
        go (x:xs) = {-# SCC go_rec #-}if isFartherThan (nodedp x) dp (sepdist x)
            then x:go xs
            else case insert x (# w,dp #) of
                Strict.Just x' -> x':xs

insertBatch :: forall expansionRatio childContainer nodeContainer tag dp.
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => [dp]
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
insertBatch (dp:dps) = {-# SCC insertBatch #-} go dps $ Node
    { nodedp    = dp
    , level     = minBound
--     , weight    = 1
    , numdp     = 1
    , children  = zero
    , nodeV     = zero
    , maxDescendentDistance = 0
--     , tag       = zero
    }
    where
        go::( ValidCT expansionRatio childContainer nodeContainer tag dp
            ) => [dp]
              -> CoverTree' expansionRatio childContainer nodeContainer tag dp
              -> CoverTree' expansionRatio childContainer nodeContainer tag dp
        go [] tree = tree
        go (x:xs) tree = go xs $ safeInsert tree (# 1,x #)

-------------------------------------------------------------------------------
-- algebra

type instance Scalar (CoverTree' expansionRatio childContainer nodeContainer tag dp) = Scalar dp

-- instance VG.Foldable (CoverTree' tag) where
--     foldr f i ct = if Map.size (childrenMap ct) == 0
--         then f (nodedp ct) i
--         else foldr (\ct' i' -> VG.foldr f i' ct') i' (Map.elems $ childrenMap ct)
--         where
--             i' = if nodedp ct `Map.member` childrenMap ct
--                 then i
--                 else f (nodedp ct) i

-- instance
--     ( ValidCT expansionRatio childContainer nodeContainer tag dp
--     ) => Comonoid (CoverTree' expansionRatio childContainer nodeContainer tag dp)
--         where
--     partition n ct = {-# SCC partition #-} [ takeFromTo (fromIntegral i*splitlen) splitlen ct | i <- [0..n-1] ]
--         where
--             splitlen = fromIntegral (ceiling $ toRational (numdp ct) / toRational n::Int)

takeFromTo :: forall expansionRatio childContainer nodeContainer tag dp.
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => Scalar dp
      -> Scalar dp
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
takeFromTo from len ct = {-# SCC takeFromTo #-}
     ct
--         { weight = nodeweight
        { nodeV = nodeV'
        , children = children'
        }
    where
        nodeweight :: Scalar dp
        nodeweight = if from <= 0
            then min len (weight ct)
            else 0

        nodeV' = fromList $ take (round len) $ drop (round $ from-nodeweight) $ toList $ nodeV ct

--         taken = nodeweight+ (fromIntegral $ VG.length nodeV') :: Scalar dp
--         nottaken = 1-nodeweight+(fromIntegral $ (VG.length $ nodeV ct)-(VG.length nodeV')) :: Scalar dp
        taken = nodeweight+ (fromIntegral $ length $ toList nodeV') :: Scalar dp
        nottaken = 1-nodeweight+(fromIntegral $ (length $ toList $ nodeV ct)-(length $ toList nodeV')) :: Scalar dp

        children' = fromList $ sndHask $ mapAccumL mapgo (from-nottaken,len-taken) $ toList $ children ct

        mapgo (from',len') child = {-# SCC mapgo #-}
            ((from'',len''),takeFromTo from' len' child)
            where
                from'' = if from' == 0
                    then 0
                    else max 0 $ from' - numdp child

                len'' = if from' == 0
                    then max 0 $ len' - numdp child
                    else if from' - len' > 0
                        then len'
                        else len'-(max 0 $ numdp child-from')


instance
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => Semigroup (CoverTree' expansionRatio childContainer nodeContainer tag dp)
        where
    {-# INLINABLE (+) #-}
    ct1 + ct2 = {-# SCC semigroup #-} case ctmerge' ct1' ct2' of
        Strict.Just (ct, []) -> ct
        Strict.Just (ct, xs) -> foldl' (+) ct xs
        Strict.Nothing ->
            (growct
                ct1'
                (dist2level_up (Proxy::Proxy expansionRatio) $ distance (nodedp ct1') (nodedp ct2'))
            ) + ct2'
        where
            ct1' = growct ct1 maxlevel
            ct2' = growct ct2 maxlevel
            maxlevel = {-# SCC maxlevel #-} maximum
                [ level ct1
                , level ct2
                , dist2level_down (Proxy::Proxy expansionRatio) $ distance (nodedp ct1) (nodedp ct2)
                ]

ctmerge' :: forall expansionRatio childContainer nodeContainer tag dp.
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> Strict.Maybe
            ( CoverTree' expansionRatio childContainer nodeContainer tag dp
            , [CoverTree' expansionRatio childContainer nodeContainer tag dp]
            )
ctmerge' ct1 ct2 = {-# SCC ctmerge' #-}
    if isFartherThan (nodedp ct1) (nodedp ct2) (sepdist ct1)
        then Strict.Nothing
        else Strict.Just
            ( safeInsert
                ( ct1
                    { children = children'
                    , numdp = sum $ map numdp $ toList children'
                    , maxDescendentDistance = coverDist ct1
--                     , maxDescendentDistance
--                         = maximum $ map (distance (nodedp ct1)) $ (stToList ct2++stToList ct1)
                    }
                )
                ( stNodeW ct2 )
            , invalidchildren++invalid_newleftovers
            )
    where
--         children' = fromList $ Strict.strictlist2list $ Strict.list2strictlist $ Map.elems childrenMap'
        children' = fromList $ Map.elems childrenMap'

        childrenMap ct = Map.fromList $ map (\v -> (nodedp v,v)) $ stChildrenList ct

        childrenMap' = newchildren `Map.union` Map.fromList
            (map (\x -> (nodedp x,growct x $ level ct1-1)) valid_newleftovers)


        validchild x = not $ isFartherThan (nodedp ct1) (nodedp x) (sepdist ct1)
        (validchildren,invalidchildren) = Data.List.partition validchild $ Map.elems $ childrenMap ct2

        (newchildren,newleftovers) = go (childrenMap ct1,[]) validchildren
        (valid_newleftovers,invalid_newleftovers) = Data.List.partition validchild newleftovers

        go (childmap,leftovers) []     = (childmap,leftovers)
        go (childmap,leftovers) (x:xs) = {-# SCC ctmerge'_go #-}
            case
                filter (Strict.isJust . snd) $ map (\(k,v) -> (k,ctmerge'' v x)) $ Map.assocs childmap of
                    [] -> go
                        ( Map.insert (nodedp x) (x { level = level ct1-1 }) childmap
                        , leftovers
                        ) xs

                    (old, Strict.Just (new,leftovers')):ys ->
                        go ( Map.insert (nodedp new) (new { level = level ct1-1 })
                             $ Map.delete old childmap
                           , leftovers'++leftovers
                           ) xs
            where
                ctmerge'' ct1 ct2 = {-# SCC ctmerge'' #-} ctmerge' ct1 ct2
                    where
                        ct1' = growct ct1 maxlevel
                        ct2' = growct ct2 maxlevel
                        maxlevel = maximum
                            [ level ct1
                            , level ct2
                            , dist2level_down (Proxy::Proxy expansionRatio) $ distance (nodedp ct1) (nodedp ct2)
                            ]

-------------------------------------------------------------------------------
-- misc helper functions

growct :: forall expansionRatio childContainer nodeContainer tag dp.
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> Int
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
growct = growct_unsafe

growct_safe :: forall expansionRatio childContainer nodeContainer tag dp.
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> Int
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
growct_safe ct d = {-# SCC growct_safe #-} if sepdist ct==0 || stIsLeaf ct
    then ct { level=d }
    else if d > level ct
        then growct (Node
            { nodedp    = nodedp ct
            , level     = level ct+1
--             , weight    = 0 -- weight ct
            , numdp     = numdp ct
            , children  = fromList [ct]
            , nodeV     = zero
            , maxDescendentDistance = maxDescendentDistance ct
--             , tag       = zero
            }
            ) d
        else ct
--     where
--         coverfactor = fromRational $ fracVal (Proxy :: Proxy expansionRatio)

-- | this version of growct does not strictly obey the separating property; it never creates ghosts, however, so seems to work better in practice
growct_unsafe :: forall expansionRatio childContainer nodeContainer tag dp.
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> Int
      -> CoverTree' expansionRatio childContainer nodeContainer tag dp
growct_unsafe ct d = {-# SCC growct_unsafe #-} if sepdist ct==0 || stIsLeaf ct
    then ct { level=d }
    else if d <= level ct
        then ct
        else newleaf
            { level     = d
            , numdp     = numdp ct
            , children  = fromList [newct]
            , maxDescendentDistance = level2coverdist (Proxy::Proxy expansionRatio) d
--             , maxDescendentDistance = maximum $ map (distance (nodedp newleaf)) $ stToList newct
            }
    where
        (newleaf,newct) = rmleaf ct

rmleaf ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp
      -> ( CoverTree' expansionRatio childContainer nodeContainer tag dp
         , CoverTree' expansionRatio childContainer nodeContainer tag dp
         )
rmleaf ct = {-# SCC rmleaf #-} if stIsLeaf (head childL)
    then (head childL, ct
        { numdp = numdp ct-1
        , children = fromList $ tail childL
        })
    else (itrleaf, ct
        { numdp = numdp ct-1
        , children = fromList $ itrtree:tail childL
        })
    where
        (itrleaf,itrtree) = rmleaf $ head childL
        childL = toList $ children ct

level2sepdist :: forall expansionRatio num.
    ( KnownFrac expansionRatio
    , Floating num
    ) =>  Proxy expansionRatio -> Int -> num
level2sepdist _ l = (fromRational $ fracVal (Proxy :: Proxy expansionRatio))**(fromIntegral l)

level2coverdist p l = level2sepdist p (l+1)

dist2level_down :: forall expansionRatio num.
    (KnownFrac expansionRatio, Floating num, QuotientField num Int) => Proxy expansionRatio -> num -> Int
dist2level_down _ d = floor $ log d / log (fromRational $ fracVal (Proxy::Proxy expansionRatio))

dist2level_up :: forall expansionRatio num.
    (KnownFrac expansionRatio, Floating num, QuotientField num Int) => Proxy expansionRatio -> num -> Int
dist2level_up _ d = ceiling $ log d / log (fromRational $ fracVal (Proxy::Proxy expansionRatio))

sepdist :: forall expansionRatio childContainer nodeContainer tag dp. (KnownFrac expansionRatio, Floating (Scalar dp)) =>
    CoverTree' expansionRatio childContainer nodeContainer tag dp -> Scalar dp
sepdist ct = level2sepdist (Proxy::Proxy expansionRatio) (level ct)

{-# INLINE coverDist #-}
coverDist :: forall expansionRatio childContainer nodeContainer tag dp.
    ( Floating (Scalar dp)
    , KnownFrac expansionRatio
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp -> Scalar dp
coverDist node = sepdist node*coverfactor
    where
        coverfactor = fromRational $ fracVal (Proxy :: Proxy expansionRatio)

{-# INLINE sepdist_child #-}
sepdist_child :: forall expansionRatio childContainer nodeContainer tag dp. (KnownFrac expansionRatio, MetricSpace dp, Floating (Scalar dp)) =>
    CoverTree' expansionRatio childContainer nodeContainer tag dp -> Scalar dp
sepdist_child ct = next -- rounddown (sing::Sing expansionRatio) $ next --next/10
    where next = sepdist ct/(fromRational $ fracVal (Proxy :: Proxy expansionRatio))

{-# INLINE roundup #-}
roundup :: forall expansionRatio d.
    ( Floating d
    , QuotientField d Int
    , KnownFrac expansionRatio
    ) => Proxy (expansionRatio::Frac) -> d -> d
roundup s d = rounddown s $ d * coverfactor
    where
        coverfactor = fromRational $ fracVal (Proxy :: Proxy expansionRatio)

{-# INLINE rounddown #-}
rounddown :: forall expansionRatio d.
    ( Floating d
    , QuotientField d Int
    , KnownFrac expansionRatio
    ) => Proxy (expansionRatio::Frac) -> d -> d
rounddown _ d = coverfactor^^(floor $ log d / log coverfactor :: Int)
    where
        coverfactor = fromRational $ fracVal (Proxy :: Proxy expansionRatio)

---------------------------------------

{-
recover ct = foldl' safeInsert ct' xs
    where
        (ct', xs) = recover' ct

recover' :: forall expansionRatio childContainer nodeContainer tag dp.
    ( MetricSpace dp

    , KnownFrac expansionRatio
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp -> (CoverTree' expansionRatio childContainer nodeContainer tag dp, [Weighted dp])
recover' ct = (ct', failed)
    where
        ct' = ct
            { childrenMap = pass
            , childrenList = Map.elems pass
            }

        (fail,pass) = Map.partition
            (\c -> not $ isFartherThan (nodedp ct) (nodedp c) (coverDist ct))
            (childrenMap ct)


        failed = concatMap stToListW $ Map.elems fail

-- unsafeMap :: forall expansionRatio childContainer nodeContainer tag dp1 dp2.
--     ( MetricSpace dp2
--     , Scalar dp1 ~ Scalar dp2
--     2
--     , KnownFrac expansionRatio
--     ) => (dp1 -> dp2) -> AddUnit (CoverTree' expansionRatio) tag dp1 -> AddUnit (CoverTree' expansionRatio) tag dp2
unsafeMap f Unit = Unit
unsafeMap f (UnitLift ct) = UnitLift $ unsafeMap' f ct

unsafeMap' :: forall expansionRatio childContainer nodeContainer tag dp1 dp2.
    ( MetricSpace dp2
    , Scalar dp1 ~ Scalar dp2
    2
    , KnownFrac expansionRatio
    ) => (dp1 -> dp2) -> CoverTree' expansionRatio childContainer nodeContainer tag dp1 -> CoverTree' expansionRatio childContainer nodeContainer tag dp2
unsafeMap' f ct = Node
    { nodedp = nodedp'
    , weight = weight ct
    , numdp = numdp ct
    , sepdist = sepdist ct
    , tag = tag ct
    , childrenMap = childrenMap'
    , childrenList = childrenList'
--     , maxDescendentDistance = maxDescendentDistance ct
    , maxDescendentDistance = maximum $ 0:map (\c -> distance (nodedp c) nodedp' + maxDescendentDistance c) childrenList'
    }
    where
        nodedp' = f $ nodedp ct
        childrenMap' = Map.fromList $ map (\c -> (nodedp c,c)) $ map (unsafeMap' f) $ childrenList ct
        childrenList' = Map.elems childrenMap'

ctmap f Unit = Unit
ctmap f (UnitLift ct) = UnitLift $ ctmap' f ct

ctmap' :: forall expansionRatio childContainer nodeContainer tag dp1 dp2.
    ( MetricSpace dp2
    , Scalar dp1 ~ Scalar dp2
    , Floating (Scalar dp1)
    2
    , Monoid tag
    , KnownFrac expansionRatio
    ) => (dp1 -> dp2) -> CoverTree' expansionRatio childContainer nodeContainer tag dp1 -> CoverTree' expansionRatio childContainer nodeContainer tag dp2
ctmap' f ct = recover $ unsafeMap' f ct


implicitChildrenMap ct = Map.union (childrenMap ct) (Map.singleton (nodedp ct) $ ct
    { nodedp = nodedp ct
    , sepdist = sepdist_child ct
    , weight = 0
    , numdp = 0
    , tag = tag ct
    , childrenMap = zero
    , childrenList = zero
    , maxDescendentDistance = 0
    })

extractLeaf :: forall expansionRatio childContainer nodeContainer tag dp.
    ( MetricSpace dp

    , KnownFrac expansionRatio
    ) => CoverTree' expansionRatio childContainer nodeContainer tag dp -> (Weighted dp, Maybe (CoverTree' expansionRatio childContainer nodeContainer tag dp))
extractLeaf ct = if stIsLeaf ct
    then (stNodeW ct, Nothing)
    else (leaf, Just $ ct
            { childrenMap = childrenMap'
            , childrenList = Map.elems childrenMap'
            }
         )
        where
            (leaf,c) = extractLeaf . head . Map.elems $ childrenMap ct

            childrenMap' = case c of
                Nothing -> Map.fromList $ tail $ Map.toList $ childrenMap ct
                Just c' -> Map.fromList $ (nodedp c', c'):(tail $ Map.toList $ childrenMap ct)
-}

-- setLeafSize :: (MetricSpace dp, KnownFrac expansionRatio) => Int -> CoverTree' expansionRatio childContainer nodeContainer tag dp -> CoverTree' expansionRatio childContainer nodeContainer tag dp
-- setLeafSize n ct = if stNumNodes ct < n
--     then ct { children = fmap singleton $ Strict.list2strictlist $ stToListW ct }
--     else ct { children = fmap (setLeafSize n) $ children ct }
--     where
-- --         singleton :: Weighted dp -> CoverTree' expansionRatio childContainer nodeContainer tag dp
--         singleton (w,dp) = Node
--             { nodedp = dp
--             , weight = w
--             , numdp = w
--             , sepdist = sepdist_child ct
--             , maxDescendentDistance = 0
--             , children = zero
--             , tag = tag ct
--             }


-------------------------------------------------------------------------------
-- training

-- instance
--     ( ValidCT expansionRatio childContainer nodeContainer tag dp
--     ) => NumDP (CoverTree' expansionRatio childContainer nodeContainer tag dp) where
--     numdp = numdp
--
-- instance
--     ( ValidCT expansionRatio childContainer nodeContainer tag dp
--     ) => HomTrainer (AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp)
--         where
--     type Datapoint (AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp) = dp
--
--     {-# INLINE train1dp #-}
--     train1dp dp = UnitLift $ Node
--         { nodedp    = dp
--         , level     = minBound
-- --         , weight    = 1
--         , numdp     = 1
--         , children  = zero
--         , nodeV     = zero
--         , maxDescendentDistance = 0
-- --         , tag       = zero
--         }
--
-- --     {-# INLINABLE train #-}
-- --     train = UnitLift . insertBatch . F.toList
--
-- trainMonoid = batch train1dp
-- trainInsert = UnitLift . insertBatch . F.toList
trainInsert = UnitLift . insertBatch . toList

-------------------------------------------------------------------------------
-- tests

{-
instance
    ( ValidCT expansionRatio childContainer nodeContainer tag (Double,Double)
    ) => Arbitrary (AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag (Double,Double))
        where
    arbitrary = do
        num :: Int <- choose (1,100)
--         xs <- replicateM num arbitrary
        xs <- replicateM num $ do
--             x <- arbitrary
--             y <- arbitrary
            x <- choose (-2**50,2**50)
            y <- choose (-2**50,2**50)
            return (x,y)
--         return $ unUnit $ train xs
        return $ train xs

-}

property_all ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp -> Bool
property_all ct = and $ map (\x -> x ct)
    [ property_covering
    , property_leveled
    , property_separating
    , property_maxDescendentDistance
    ]

property_covering ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp -> Bool
property_covering Unit = True
property_covering (UnitLift node) = if not $ stIsLeaf node
    then VG.maximum (fmap (distance (nodedp node) . nodedp) $ children node) < coverDist node
      && VG.and (fmap (property_covering . UnitLift) $ children node)
    else True

property_leveled ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp -> Bool
property_leveled (Unit) = True
property_leveled (UnitLift node)
    = VG.all (== VG.head xs) xs
   && VG.and (fmap (property_leveled . UnitLift) $ children node)
    where
        xs = fmap level $ children node

property_separating ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp -> Bool
property_separating Unit = True
property_separating (UnitLift node) = if length (VG.toList $ children node) > 1
    then VG.foldl1 min ((mapFactorial stMaxDistance) $ children node) > sepdist_child node
      && VG.and (fmap (property_separating . UnitLift) $ children node)
    else True
    where
        mapFactorial :: (VG.Vector v a, VG.Vector v b) =>(a -> a -> b) -> v a -> v b
        mapFactorial f = VG.fromList . mapFactorial' f . VG.toList
        mapFactorial' :: (a -> a -> b) -> [a] -> [b]
        mapFactorial' f xs = go xs []
            where
                go [] ys = ys
                go (x:xs) ys = go xs (map (f x) xs + ys)

property_maxDescendentDistance ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp -> Bool
property_maxDescendentDistance Unit = True
property_maxDescendentDistance (UnitLift node)
    = and (map (property_maxDescendentDistance . UnitLift) $ stChildrenList node)
   && and (map (\dp -> distance dp (nodedp node) <= maxDescendentDistance node) $ stDescendents node)

property_validmerge ::
    ( ValidCT expansionRatio childContainer nodeContainer tag dp
    ) => ( AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp -> Bool )
      -> AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp
      -> AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp
      -> Bool
property_validmerge prop (UnitLift ct1) (UnitLift ct2) = prop . UnitLift $ ct1 + ct2

-- property_lossless :: [(Double,Double)] ->  Bool
-- property_lossless [] = True
-- property_lossless xs = Set.fromList xs == dpSet ct
--     where
--         UnitLift ct = train xs :: AddUnit (CoverTree' (2/1) V.Vector V.Vector) () (Double,Double)
--
--         dpSet :: (Ord dp) => CoverTree' expansionRatio V.Vector V.Vector tag dp -> Set.Set dp
--         dpSet = Set.fromList . dpList
--             where
--                 dpList :: CoverTree' expansionRatio V.Vector V.Vector tag dp -> [dp]
--                 dpList node = nodedp node:(concat . fmap dpList . V.toList $ children node)

-- property_numdp ::
--     ( ValidCT expansionRatio childContainer nodeContainer tag dp
--     ) => AddUnit (CoverTree' expansionRatio childContainer nodeContainer) tag dp -> Bool
-- property_numdp Unit = True
-- property_numdp (UnitLift node) = numdp node == sum (map fst $ stToList node)
-- property_numdp (UnitLift node) = numdp node == sum (map fst $ stToListW node)

