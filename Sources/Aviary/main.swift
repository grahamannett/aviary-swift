import AviaryCLI

@main
enum AviaryMain {
    static func main() async {
        await AviaryRoot.mainAsync()
    }
}
