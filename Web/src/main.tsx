import { createRoot } from "react-dom/client"
import { StudyApp } from "./StudyApp"
import "@fontsource-variable/inter/wght.css"
import "@fontsource/pt-serif/400.css"
import "./index.css"

createRoot(document.getElementById("root")!).render(<StudyApp />)
