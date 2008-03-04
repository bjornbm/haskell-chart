-----------------------------------------------------------------------------
-- |
-- Module      :  Graphics.Rendering.Chart.Renderable
-- Copyright   :  (c) Tim Docker 2006
-- License     :  BSD-style (see chart/COPYRIGHT)

module Graphics.Rendering.Chart.Renderable where

import qualified Graphics.Rendering.Cairo as C
import Control.Monad
import Data.List ( nub, partition, transpose )

import Graphics.Rendering.Chart.Types
import Graphics.Rendering.Chart.Plot

-- | A Renderable is a record of functions required to layout a
-- graphic element.
data Renderable = Renderable {

   -- | a Cairo action to calculate a minimum size,
   minsize :: C.Render RectSize,

   -- | a Cairo action for drawing it within a specified rectangle.
   render ::  Rect -> C.Render ()
}

-- | A type class abtracting the conversion of a value to a
-- Renderable.

class ToRenderable a where
   toRenderable :: a -> Renderable

emptyRenderable = Renderable {
   minsize = return (0,0),
   render  = \_ -> return ()
}

addMargins :: (Double,Double,Double,Double) -> Renderable -> Renderable
addMargins (t,b,l,r) rd = Renderable { minsize = mf, render = rf }
  where
    mf = do
        (w,h) <- minsize rd
        return (w+l+r,h+t+b)

    rf r1@(Rect p1 p2) = do
        render rd (Rect (p1 `pvadd` (Vector l t)) (p2 `pvsub` (Vector r b)))

fillBackground :: CairoFillStyle -> Renderable -> Renderable
fillBackground fs r = Renderable { minsize = minsize r, render = rf }
  where
    rf rect@(Rect p1 p2) = do
        C.save
        setClipRegion p1 p2
        setFillStyle fs
        C.paint
        C.restore
	render r rect

vertical, horizontal :: [(Double,Renderable)] -> Renderable 
vertical rs = grid [1] (map fst rs) [[snd r] | r <- rs]
horizontal rs = grid (map fst rs) [1] [[snd r | r <- rs]]

grid :: [Double] -> [Double] -> [[Renderable]] -> Renderable
grid we he rss = Renderable { minsize = mf, render = rf }
  where
    mf = do
      msizes <- getSizes
      let widths = (map.map) fst msizes
      let heights = (map.map) snd msizes
      return ((sum.map maximum.transpose) widths,(sum.map maximum) heights)

    rf (Rect p1 p2) = do
      msizes <- getSizes
      let widths = (map maximum.(map.map) fst.transpose) msizes
      let heights = (map maximum.(map.map) snd) msizes
      let widths1 = allocate (p_x p2 - p_x p1 - sum widths) we widths
      let heights1 = allocate (p_y p2 - p_y p1 - sum heights) he heights
      let xs = scanl (+) (p_x p1) widths1
      let ys = scanl (+) (p_y p1) heights1
      
      forM_ (zip3 rss ys (tail ys))  $ \(rs,y0,y1) ->
        forM_ (zip3 rs xs (tail xs))  $ \(r,x0,x1) ->
          render r (Rect (Point x0 y0) (Point x1 y1))

    getSizes = (mapM.mapM) minsize rss

allocate :: Double -> [Double] -> [Double] -> [Double]
allocate extra ws vs = zipWith (+) vs (extras++[0,0..])
  where
    total = sum ws 
    extras = [ extra * v / total | v <- ws ]

renderableToPNGFile :: Renderable -> Int -> Int -> FilePath -> IO ()
renderableToPNGFile chart width height path = 
    C.withImageSurface C.FormatARGB32 width height $ \result -> do
    C.renderWith result $ rfn
    C.surfaceWriteToPNG result path
  where
    rfn = do
        alignPixels
	render chart rect

    rect = Rect (Point 0 0) (Point (fromIntegral width) (fromIntegral height))

renderableToPDFFile :: Renderable -> Int -> Int -> FilePath -> IO ()
renderableToPDFFile chart width height path = 
    C.withPDFSurface path (fromIntegral width) (fromIntegral height) $ \result -> do
    C.renderWith result $ rfn
    C.surfaceFinish result
  where
    rfn = do
	render chart rect
        C.showPage

    rect = Rect (Point 0 0) (Point (fromIntegral width) (fromIntegral height))

renderableToPSFile :: Renderable -> Int -> Int -> FilePath -> IO ()
renderableToPSFile chart width height path = 
    C.withPSSurface path (fromIntegral width) (fromIntegral height) $ \result -> do
    C.renderWith result $ rfn
    C.surfaceFinish result
  where
    rfn = do
	render chart rect
        C.showPage

    rect = Rect (Point 0 0) (Point (fromIntegral width) (fromIntegral height))

alignPixels :: C.Render ()
alignPixels = do
    -- move to centre of pixels so that stroke width of 1 is
    -- exactly one pixel 
    C.translate 0.5 0.5

----------------------------------------------------------------------
-- Legend

data LegendStyle = LegendStyle {
   legend_label_style :: CairoFontStyle,
   legend_margin :: Double,
   legend_plot_size :: Double
}

data Legend = Legend Bool LegendStyle [(String,Plot)]

instance ToRenderable Legend where
  toRenderable l = Renderable {
    minsize=minsizeLegend l,
    render=renderLegend l
  }

minsizeLegend :: Legend -> C.Render RectSize
minsizeLegend (Legend _ ls plots) = do
    let labels = nub $ map fst plots
    lsizes <- mapM textSize labels
    lgap <- legendSpacer
    let lm = legend_margin ls
    let pw = legend_plot_size ls
    let h = maximum  [h | (w,h) <- lsizes]
    let n = fromIntegral (length lsizes)
    let w = sum [w + lgap | (w,h) <- lsizes] + pw * (n+1) + lm * (n-1)
    return (w,h)

renderLegend :: Legend -> Rect -> C.Render ()
renderLegend (Legend _ ls plots) (Rect rp1 rp2) = do
    foldM_ rf rp1 $ join_nub plots
  where
    lm = legend_margin ls
    lps = legend_plot_size ls

    rf :: Point -> (String,[Plot]) -> C.Render Point
    rf p1 (label,theseplots) = do
        (w,h) <- textSize label
	lgap <- legendSpacer
	let p2 = (p1 `pvadd` Vector lps 0)
        mapM_ (\p -> plot_render_legend p (mkrect p1 rp1 p2 rp2)) theseplots
	let p3 = Point (p_x p2 + lgap) (p_y rp1)
	drawText HTA_Left VTA_Top p3 label
        return (p3 `pvadd` Vector (w+lm) 0)
    join_nub :: [(String, a)] -> [(String, [a])]
    join_nub ((x,a1):ys) = case partition ((==x) . fst) ys of
                           (xs, rest) -> (x, a1:map snd xs) : join_nub rest
    join_nub [] = []

legendSpacer = do
    (lgap,_) <- textSize "X"
    return lgap

defaultLegendStyle = LegendStyle {
    legend_label_style=defaultFontStyle,
    legend_margin=20,
    legend_plot_size=20
}


----------------------------------------------------------------------
-- Labels

label :: CairoFontStyle -> HTextAnchor -> VTextAnchor -> String -> Renderable
label fs hta vta = rlabel fs hta vta 0

rlabel :: CairoFontStyle -> HTextAnchor -> VTextAnchor -> Double -> String -> Renderable
rlabel fs hta vta rot s = Renderable { minsize = mf, render = rf }
  where
    mf = do
       C.save
       setFontStyle fs
       (w,h) <- textSize s
       C.restore
       let sz' = (w*acr+h*asr,w*asr+h*acr)
       return sz'
    rf (Rect p1 p2) = do
       C.save
       setFontStyle fs
       sz@(w,h) <- textSize s
       C.translate (xadj sz hta (p_x p1) (p_x p2)) (yadj sz vta (p_y p1) (p_y p2))
       C.rotate rot'
       C.moveTo (-w/2) (h/2)
       C.showText s
       C.restore
    xadj (w,h) HTA_Left x1 x2 =  x1 +(w*acr+h*asr)/2
    xadj (w,h) HTA_Centre x1 x2 = (x1 + x2)/2
    xadj (w,h) HTA_Right x1 x2 =  x2 -(w*acr+h*asr)/2
    yadj (w,h) VTA_Top y1 y2 =  y1 +(w*asr+h*acr)/2
    yadj (w,h) VTA_Centre y1 y2 = (y1+y2)/2
    yadj (w,h) VTA_Bottom y1 y2 =  y2 - (w*asr+h*acr)/2

    rot' = rot / 180 * pi
    (cr,sr) = (cos rot', sin rot')
    (acr,asr) = (abs cr, abs sr)

-- a quick test to display labels with all combinations
-- of anchors
labelTest rot = renderableToPNGFile r 800 800 "labels.png"
  where
    r = fillBackground white $ grid [1,1,1] [1,1,1] ls
    ls = [ [addMargins (20,20,20,20) $ fillBackground blue $ crossHairs $ rlabel fs h v rot s | h <- hs] | v <- vs ]
    s = "Labels"
    hs = [HTA_Left, HTA_Centre, HTA_Right]
    vs = [VTA_Top, VTA_Centre, VTA_Bottom]
    white = solidFillStyle 1 1 1
    blue = solidFillStyle 0.8 0.8 1
    fs = fontStyle "sans" 30 C.FontSlantNormal C.FontWeightBold
    crossHairs r =Renderable {
      minsize = minsize r,
      render = \rect@(Rect (Point x1 y1) (Point x2 y2)) -> do
          let xa = (x1 + x2) / 2
          let ya = (y1 + y2) / 2
          strokeLines [Point x1 ya,Point x2 ya]
          strokeLines [Point xa y1,Point xa y2]
          render r rect
    }
    
