import SwiftUI
import UIKit
import Foundation
import CoreText
struct RemoteImage: View {
    let path: String?
    var cornerRadius: CGFloat = 16
    var systemFallback: String = "square.stack.3d.up.fill"

    var body: some View {
        Group {
            if let url = StoreAPI.shared.absoluteURL(path) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else if phase.error != nil { fallback }
                    else { ZStack { StoreTheme.field; ProgressView().tint(StoreTheme.accent) } }
                }
            } else { fallback }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [StoreTheme.field, StoreTheme.surfaceBorder], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: systemFallback).font(.system(size: 23, weight: .semibold)).foregroundStyle(StoreTheme.accent)
        }
    }
}

struct InstallPill: View {
    var title = "تثبيت"
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(title).font(AppFont.bold(13)).foregroundStyle(StoreTheme.onAccent)
                .padding(.horizontal, 17).frame(height: 32)
                .background(StoreTheme.accent).clipShape(Capsule())
        }.buttonStyle(.plain)
    }
}

struct SectionTitle: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(AppFont.black(20)).foregroundStyle(StoreTheme.textPrimary)
            Spacer(minLength: 8)
        }.padding(.horizontal, StoreTheme.pageHorizontal)
    }
}

struct AppIconView: View {
    let app: StoreApp
    var size: CGFloat = 64
    var body: some View {
        RemoteImage(path: app.iconUrl, cornerRadius: size * 0.23)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: size * 0.23).stroke(Color.white.opacity(0.08), lineWidth: 0.7))
    }
}

struct BandCard: View {
    let app: StoreApp
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AppIconView(app: app, size: 58)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(app.name).font(AppFont.bold(15)).foregroundStyle(StoreTheme.textPrimary).lineLimit(2).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(app.categories?.first ?? "تطبيق").font(AppFont.regular(12)).foregroundStyle(StoreTheme.textSecondary).lineLimit(1)
                }
                InstallPill()
            }
            if let notes = app.notes, !notes.isEmpty {
                Text(notes.replacingOccurrences(of: "\n", with: " "))
                    .font(AppFont.regular(11.5)).foregroundStyle(StoreTheme.textSecondary).lineLimit(2)
            }
        }
        .padding(14).frame(width: 310, height: 126, alignment: .top).storeCard(radius: 19)
    }
}

struct ShowcaseCard: View {
    let app: StoreApp
    var body: some View {
        VStack(spacing: 14) {
            AppIconView(app: app, size: 76)
            VStack(spacing: 4) {
                Text(app.name).font(AppFont.bold(15)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
                Text("الإصدار \(app.version ?? "—")").font(AppFont.regular(11)).foregroundStyle(StoreTheme.textSecondary)
            }
            InstallPill()
        }
        .padding(16).frame(width: 168, height: 192).storeCard(radius: 22)
    }
}

struct LargeListRow: View {
    let app: StoreApp
    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: app, size: 62)
            VStack(alignment: .trailing, spacing: 5) {
                Text(app.name).font(AppFont.bold(15)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
                Text(app.notes ?? "الإصدار \(app.version ?? "—")").font(AppFont.regular(11.5)).foregroundStyle(StoreTheme.textSecondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .trailing)
            InstallPill()
        }.padding(.vertical, 10)
    }
}

struct CategoryStripCard: View {
    let category: StoreCategory
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StoreTheme.field)
                Text(category.emoji ?? "•").font(.system(size: 20, weight: .semibold)).foregroundStyle(StoreTheme.accent)
            }.frame(width: 43, height: 43)
            VStack(alignment: .trailing, spacing: 2) {
                Text(category.name).font(AppFont.bold(13)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
                if let count = category.count { Text("\(count) تطبيق").font(AppFont.regular(10.5)).foregroundStyle(StoreTheme.textSecondary) }
            }
        }.padding(.horizontal, 12).frame(height: 65).storeCard(radius: 17)
    }
}

struct CategoryGridTile: View {
    let category: StoreCategory
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack {
                Spacer()
                ZStack {
                    Circle().fill(StoreTheme.accent.opacity(0.13))
                    Text(category.emoji ?? "•").font(.system(size: 24, weight: .bold)).foregroundStyle(StoreTheme.accent)
                }.frame(width: 50, height: 50)
            }
            Spacer(minLength: 2)
            Text(category.name).font(AppFont.bold(14)).foregroundStyle(StoreTheme.textPrimary).lineLimit(1)
            if let count = category.count { Text("\(count) تطبيق").font(AppFont.regular(10.5)).foregroundStyle(StoreTheme.textSecondary) }
        }.padding(14).frame(height: 132).storeCard(radius: 20)
    }
}
