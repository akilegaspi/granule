module Language.Granule.Checker.LaTeX where

import Data.List (intercalate)

data Derivation =
  Node String [Derivation] | Leaf String
    deriving Eq

instance Show Derivation where
  show (Leaf s) = s
  show (Node c premises) =
    "\\dfrac{" <> intercalate " \\quad " (map show premises) <> "}{" <> c <> "}"

mkDocument :: String -> String
mkDocument doc =
 "\\documentclass{article}\
 \\\usepackage{amsmath}\
 \\\newcommand{check}[4]{#1 \\vdash #2 \\Leftarrow #3}\
 \\\begin{document}" <> doc <>
 "\\end{document}"
