import UIKit

protocol PhotoImageLoading {
    func image(for photo: Photo) -> UIImage?
    func thumbnail(for photo: Photo, maxPixelSize: CGFloat) -> UIImage?
}
