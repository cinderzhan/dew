import SwiftUI

struct TodoTab: View {
    @EnvironmentObject var todos: TodoStore
    let skin: Skin

    @State private var draft = ""
    @State private var draftKind: TodoKind = .normal
    @FocusState private var inputFocused: Bool

    var body: some View {
        // 显式容器，理由同 AgentsTab
        VStack(alignment: .leading, spacing: 0) {
            input

            if todos.items.isEmpty {
                EmptyHint(text: L(.emptyTodo), skin: skin)
            } else {
                ForEach(TodoKind.allCases, id: \.self) { kind in
                    let list = todos.items(of: kind)
                    if !list.isEmpty {
                        GroupHeader(title: kind.label, skin: skin,
                                    accent: kind == .high ? skin.signal : nil)
                        ForEach(list) { TodoRow(item: $0, skin: skin) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var input: some View {
        HStack(spacing: 7) {
            TextField(L(.todoPlaceholder), text: $draft)
                .textFieldStyle(.plain)
                .font(Metrics.bodyFont)
                .foregroundStyle(skin.text)
                .focused($inputFocused)
                .onSubmit {
                    todos.add(draft, kind: draftKind)
                    draft = ""
                }

            // 三分类切换。做成一排小字而不是下拉，是为了省掉一次点击。
            HStack(spacing: 3) {
                ForEach(TodoKind.allCases, id: \.self) { k in
                    let on = draftKind == k
                    Button { draftKind = k } label: {
                        Text(shortLabel(k))
                            .font(.system(size: 9.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? (k == .high ? skin.signal : skin.text) : skin.faint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(on ? skin.selection : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(skin.line).frame(height: 0.5) }
    }

    private func shortLabel(_ k: TodoKind) -> String {
        switch k {
        case .high: return L(.todoHighShort)
        case .daily: return L(.todoDailyShort)
        case .normal: return L(.todoNormalShort)
        }
    }
}

struct TodoRow: View {
    @EnvironmentObject var todos: TodoStore
    let item: TodoItem
    let skin: Skin
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // 复选框本体 12pt，但可点区域放大到 24pt——12pt 的靶子在快速点击时
            // 十有八九落在外面，这就是「不灵敏」的来源。
            Button { todos.toggle(item) } label: {
                checkbox
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -4)
            .padding(.leading, -6)

            Text(item.title)
                .font(item.kind == .high && !item.done
                      ? .system(size: 12.5, weight: .semibold)
                      : Metrics.bodyFont)
                .foregroundStyle(item.done ? skin.faint : skin.text)
                .strikethrough(item.done, color: skin.faint)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // 点文字也能勾选。待办类产品的惯例，也把有效靶面扩到整行。
                .onTapGesture { todos.toggle(item) }

            if hovering {
                Button { todos.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(skin.faint)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -3)
                .padding(.trailing, -4)
            }
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, Metrics.rowVPad)
        .background(hovering ? skin.selection : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(TodoKind.allCases, id: \.self) { k in
                if k != item.kind {
                    Button(L(.moveTo, k.label)) { todos.move(item, to: k) }
                }
            }
            Divider()
            Button(L(.delete), role: .destructive) { todos.remove(item) }
        }
    }

    private var checkbox: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(item.done ? .clear : skin.faint, lineWidth: 1.2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(item.done ? skin.dim : .clear)
            )
            .frame(width: 12, height: 12)
            .overlay {
                if item.done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(skin.tint.opacity(1))
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
    }
}
