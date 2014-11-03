{-# LANGUAGE TemplateHaskell,DataKinds,RebindableSyntax #-}
module HLearn.Optimization.LineMinimization.Univariate
    (
    -- * advanced functions
    -- ** bracket
    LineBracket (..)
    , lineBracket 

    -- ** minimizers
    , GoldenSectionSearch (..)
    , goldenSectionSearch 

    , Brent (..)
    , brent
    , brentTollerance
    )
    where

import SubHask

import HLearn.History
import HLearn.Optimization.Common

-------------------------------------------------------------------------------
-- line bracketing

data LineBracket a = LineBracket 
    { _ax :: !a
    , _bx :: !a
    , _cx :: !a
    , _fa :: !a
    , _fb :: !a
    , _fc :: !a 
    }
    deriving (Read,Show,Typeable)

-- | finds two points ax and cs between which a minimum is guaranteed to exist
-- this is a transliteration of the 'lineBracket' function from the \"Numerical
-- Recipes\" series
lineBracket :: 
    ( Field a
    , Normed a
    , Ord a
    , IsScalar a
    , HistoryMonad m
    , Reportable m a
    , Reportable m (LineBracket a)
    , Show a
    ) => (a -> a) -> a -> a -> m (LineBracket a)
lineBracket !f !pt1 !pt2 = do
    let gold = 1.618034

    let (ax,bx) = if f pt1 > f pt2
            then (pt1,pt2)
            else (pt2,pt1)

    let cx = bx+gold*(bx-ax)

    let lb0 = LineBracket
            { _ax = ax
            , _bx = bx
            , _cx = cx
            , _fa = f ax
            , _fb = f bx
            , _fc = f cx
            }

    optimize 
        (step_LineBracket f) 
        lb0
        stop_LineBracket

stop_LineBracket :: (HistoryMonad m, Ord a) => LineBracket a -> LineBracket a -> m Bool
stop_LineBracket _ lb = if _fb lb /= _fb lb
    then error "NaN in linebracket"
    else return $ _fb lb <= _fc lb

step_LineBracket :: 
    ( Ord a
    , Normed a
    , Field a
    , IsScalar a
    , Reportable m a
    , HistoryMonad m
    , Show a
    ) => (a -> a) -> LineBracket a -> m (LineBracket a)
step_LineBracket !f lb@(LineBracket ax bx cx fa fb fc) = --trace ("lb="++show lb) $ 
  return ret
    where
        sign a b = if b>0 then abs a else -(abs a)
        tiny = 1e-20
        glimit = 100
        gold = 1.618034

        r = (bx-ax)*(fb-fc)
        q = (bx-cx)*(fb-fa)
        u = bx-((bx-cx)*q-(bx-ax)*r)/2*(sign (max (abs $ q-r) tiny) (q-r))
        fu = f u
        ulim = bx+glimit*(cx-bx)

        ret = if (bx-u)*(u-cx) > 0
            then if fu < fc -- Got a minimum between a and c
                then lb
                    { _ax = bx
                    , _bx = u
                    , _fa = fb
                    , _fb = fu
                    }
                else if fu > fb -- Got a minimum between a and u
                    then lb
                        { _cx = u
                        , _fc = fu
                        }
                    else let u' = cx+gold*(cx-bx) in lb -- Parabolic fit was no use.  Use default magnification
                        { _ax = bx
                        , _bx = cx
                        , _cx = u'
                        , _fa = fb
                        , _fb = fc
                        , _fc = f u' 
                        }
            else if (cx-u)*(u-ulim) > 0 -- parabolic fit is between c and its allowed limit
                then if fu < fc 
                    then let u' = cx+gold*(cx-bx) in lb
                        { _ax = cx
                        , _bx = u
                        , _cx = u'
                        , _fa = fc
                        , _fb = fu
                        , _fc = f u'
                        } 
                    else lb
                        { _ax = bx 
                        , _bx = cx
                        , _cx = u
                        , _fa = fb
                        , _fb = fc
                        , _fc = fu
                        }
                else if (u-ulim)*(ulim-cx) >= 0
                    then lb -- limit parabolic u to maximum allowed value
                        { _ax = bx
                        , _bx = cx
                        , _cx = ulim
                        , _fa = fb
                        , _fb = fc
                        , _fc = f ulim
                        }
                    else let u' = cx+gold*(cx-bx) in lb -- reject parabolic u, use default magnification
                        { _ax = bx
                        , _bx = cx
                        , _cx = u'
                        , _fa = fb
                        , _fb = fc
                        , _fc = f u'
                        }

-------------------------------------------------------------------------------
-- golden section search

data GoldenSectionSearch a = GoldenSectionSearch
    { _gss_fxb :: !a
    , _gss_fxc :: !a
    , _gss_xa :: !a
    , _gss_xb :: !a
    , _gss_xc :: !a
    , _gss_xd :: !a
    }
    deriving (Typeable)

-- instance (Ord a, IsScalar a) => Has_fx1 GoldenSectionSearch a where
--     fx1 = lens getter setter
--         where
--             getter gss = min (_gss_fxb gss) (_gss_fxc gss)
--             setter = error "GoldenSectionSearch fx1 setter"
-- 
-- instance (Ord a, IsScalar a) => Has_x1 GoldenSectionSearch a where
--     x1 = lens getter setter
--         where
--             getter gss = if _gss_fxb gss < _gss_fxc gss
--                 then _gss_xb gss
--                 else _gss_xc gss
--             setter = error "GoldenSectionSearch x1 setter"

---------------------------------------

-- | Finds the minimum of a "poorly behaved" function; usually brent's
-- method is much better. 
-- This is a transliteration of the gss routine from the \"Numerical
-- Recipes\" series
goldenSectionSearch f (LineBracket ax bx cx fa fb fc) stop = do
    let r = 0.61803399
        c = 1-r

    let xb = if abs (cx-bx) > abs (bx-ax)
            then bx
            else bx-c*(bx-ax)

    let xc = if abs (cx-bx) > abs (bx-ax)
            then bx+c*(cx-bx)
            else bx

    let gss0 = GoldenSectionSearch
            { _gss_fxb = f xb
            , _gss_fxc = f xc
            , _gss_xa = ax
            , _gss_xb = xb
            , _gss_xc = xc
            , _gss_xd = cx
            }

    optimize
        (step_GoldenSectionSearch f) 
        gss0
        stop

----------------------------------------

stop_GoldenSectionSearch :: 
    ( Normed a
    , Rng a
    , Ord a
    , IsScalar a
    , HistoryMonad m
    ) => a -> GoldenSectionSearch a -> m Bool
stop_GoldenSectionSearch tol (GoldenSectionSearch _ _ !x0 !x1 !x2 !x3 ) = return $ abs (x3-x0) <= tol*(abs x1+abs x2)

step_GoldenSectionSearch :: 
    ( Ord a
    , Field a
    , Reportable m a
    , HistoryMonad m
    ) => (a -> a) -> GoldenSectionSearch a -> m (GoldenSectionSearch a)
step_GoldenSectionSearch f (GoldenSectionSearch f1 f2 x0 x1 x2 x3) = return $ if f2 < f1
    then let x' = r*x2+c*x3 in GoldenSectionSearch f2 (f x') x1 x2 x' x3
    else let x' = r*x1+c*x0 in GoldenSectionSearch (f x') f1 x0 x' x1 x2
    where
        r = 0.61803399
        c = 1-r
    
-------------------------------------------------------------------------------
-- Brent's methos

data Brent a = Brent 
    { _a :: !a
    , _b :: !a
    , _d :: !a
    , _e :: !a
    , _fv :: !a
    , _fw :: !a
    , _fx :: !a
    , _v :: !a
    , _w :: !a
    , _x :: !a 
    }
    deriving (Read,Show,Typeable)
makeLenses ''Brent

-- instance IsScalar v => Has_x1 Brent v where 
--     x1 = x
-- 
-- instance IsScalar v => Has_fx1 Brent v where
--     fx1 = lens getter setter 
--         where
--             getter s = (s^.fv + s^.fw + s^.fx)/3
--             setter = error "Brent.fx1 undefined"

-- | Brent's method uses parabolic interpolation.  
-- This function is a transliteration of the method found in numerical recipes.
brent :: 
    ( Ord a
    , Field a
    , Normed a
    , IsScalar a
    , HistoryMonad m
    , Reportable m a
    , Reportable m (Brent a)
    ) => (a -> a) 
      -> LineBracket a 
      -> StopCondition m (Brent a)
      -> m (Brent a)
brent f (LineBracket ax bx cx fa fb fc) = optimize
    (step_Brent f) 
    $ Brent
        { _a = min ax cx
        , _b = max ax cx
        , _d = zero
        , _e = zero
        , _v = bx
        , _w = bx
        , _x = bx
        , _fv = f bx
        , _fw = f bx
        , _fx = f bx
        }

brentTollerance :: 
    ( Ord a
    , Field a
    , Normed a
    , IsScalar a
    , HistoryMonad m
    ) => a -> Brent a -> Brent a -> m Bool
brentTollerance tol _ opt = return $ abs (x-xm) <= tol2'-0.5*(b-a)
    where
        (Brent a b d e fv fw fx v w x) = opt
        xm = 0.5*(a+b)
        tol1' = tol*(abs x)+zeps
        tol2' = 2*tol1'
        zeps = 1e-10

step_Brent :: 
    ( Field a
    , Normed a
    , IsScalar a
    , Ord a
    , HistoryMonad m
    , Reportable m a
    ) => (a -> a) -> Brent a -> m (Brent a)
step_Brent f brent@(Brent a b d e fv fw fx v w x) = return brent'
    where
        cgold = 0.3819660
        zeps = 1e-10
        sign a b = if b>0 then abs a else -(abs a)
        tol = 1e-6

        xm = 0.5*(a+b)
        tol1' = tol*(abs x)+zeps
        tol2' = 2*tol1'

        (d',e') = if abs e > tol1'
            then let
                r' = (x-w)*(fx-fv)
                q' = (x-v)*(fx-fw)
                p' = (x-v)*q'-(x-w)*r'
                q'' = 2*(q'-r')
                p'' = if q''>0 then -p' else p'
                q''' = abs q''
                etemp' = e
                in if abs p'' >= abs (0.5*q'''*etemp') || p'' <= q'''*(a-x) || p'' >= q'''*(b-x)
                    then let e'' = if x>=xm then a-x else b-x in (cgold*e'',e'')
                    else let d''=p''/q'''; u''=x+d'' in
                        if u''-a < tol2' || b-u'' < tol2'
                            then (sign tol1' (xm-x),d)
                            else (d'',d)
            else let e'' = if x>=xm then a-x else b-x in (cgold*e'',e'')

        u' = if abs d' >= tol1'
            then x+d'
            else x+sign tol1' d'
        fu' = f u'

        brent' = if fu' <= fx
            then brent
                { _e = e'
                , _d = d'
                , _a = if u' >= x then x else a
                , _b = if u' >= x then b else x
                , _v = w
                , _w = x
                , _x = u'
                , _fv = fw
                , _fw = fx
                , _fx = fu'
                }
            else brent
                { _e = e'
                , _d = d'
                , _a = if u' < x then u' else a
                , _b = if u' < x then b  else u'
                , _v  = if fu' <= fw || w==x then w   else if fu' <= fv || v==x || v==w then u'  else v
                , _fv = if fu' <= fw || w==x then fw  else if fu' <= fv || v==x || v==w then fu' else fv
                , _w  = if fu' <= fw || w==x then u'  else e
                , _fw = if fu' <= fw || w==x then fu' else fw
                }

