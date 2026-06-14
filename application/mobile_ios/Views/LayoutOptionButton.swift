import SwiftUI

struct LayoutOptionButton: View {
    let mode: String
    let badge1: String
    let badge2: String
    let isVertical: Bool
    @Binding var selectedMode: String
    
    var body: some View {
        let isSelected = selectedMode == mode
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedMode = mode
            }
        }) {
            VStack(spacing: 6) {
                // Layout Preview Box
                let layoutFlex = isVertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
                layoutFlex {
                    // Badge 1
                    Text(badge1)
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(badge1 == "EN" ? Color.blue.opacity(0.35) : Color.red.opacity(0.3))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(badge1 == "EN" ? Color.blue.opacity(0.5) : Color.red.opacity(0.45), lineWidth: 1)
                                )
                        )
                        .opacity(isSelected ? 1.0 : 0.5)
                    
                    // Badge 2
                    Text(badge2)
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(badge2 == "EN" ? Color.blue.opacity(0.35) : Color.red.opacity(0.3))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(badge2 == "EN" ? Color.blue.opacity(0.5) : Color.red.opacity(0.45), lineWidth: 1)
                                )
                        )
                        .opacity(isSelected ? 1.0 : 0.5)
                }
                .padding(4)
                .frame(height: 38)
                .background(Color.black.opacity(0.3))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                
                // Label description
                Text(isVertical ? "Trên - Dưới" : "Trái - Phải")
                    .font(.system(size: 9, weight: isSelected ? .bold : .regular))
                    .foregroundColor(isSelected ? Color(hex: "14b8a6") : .gray)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color(hex: "14b8a6").opacity(0.08) : Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color(hex: "14b8a6") : Color.white.opacity(0.08), lineWidth: 1.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
