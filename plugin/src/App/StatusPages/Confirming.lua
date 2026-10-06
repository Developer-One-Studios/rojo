local Rojo = script:FindFirstAncestor("Rojo")
local Plugin = Rojo.Plugin
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local Settings = require(Plugin.Settings)
local Theme = require(Plugin.App.Theme)
local TextButton = require(Plugin.App.Components.TextButton)
local BorderedContainer = require(Plugin.App.Components.BorderedContainer)
local ScrollingFrame = require(Plugin.App.Components.ScrollingFrame)
local StudioPluginGui = require(Plugin.App.Components.Studio.StudioPluginGui)
local Tooltip = require(Plugin.App.Components.Tooltip)
local PatchVisualizer = require(Plugin.App.Components.PatchVisualizer)
local StringDiffVisualizer = require(Plugin.App.Components.StringDiffVisualizer)
local TableDiffVisualizer = require(Plugin.App.Components.TableDiffVisualizer)

local e = Roact.createElement

local CONFLICT_LIST_HEIGHT = 140

--[[
	Lists changes that are being held back because they'd overwrite work a
	teammate synced more recently.
]]
local function ConflictList(props)
	return Theme.with(function(theme)
		local rows = {
			Layout = e("UIListLayout", {
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 2),
			}),
		}

		for index, conflict in props.conflicts do
			rows["Conflict" .. index] = e("TextLabel", {
				Text = props.describeConflict(conflict),
				FontFace = theme.Font.Thin,
				TextSize = theme.TextSize.Small,
				TextColor3 = theme.SubTextColor,
				TextTransparency = props.transparency,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextWrapped = true,
				Size = UDim2.new(1, -4, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = index,
			})
		end

		local count = #props.conflicts
		local headingHeight = (theme.TextSize.Body + 3) * 2

		return e(BorderedContainer, {
			transparency = props.transparency,
			size = UDim2.new(1, 0, 0, CONFLICT_LIST_HEIGHT),
			layoutOrder = props.layoutOrder,
		}, {
			Heading = e("TextLabel", {
				Text = string.format(
					"Holding back %s that would overwrite newer work from teammates:",
					if count == 1 then "1 change" else count .. " changes"
				),
				FontFace = theme.Font.Main,
				TextSize = theme.TextSize.Body,
				TextColor3 = theme.Diff.Warning,
				TextTransparency = props.transparency,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, -16, 0, headingHeight),
				Position = UDim2.new(0, 8, 0, 6),
				BackgroundTransparency = 1,
			}),

			List = e(ScrollingFrame, {
				size = UDim2.new(1, -16, 1, -(headingHeight + 14)),
				position = UDim2.new(0, 8, 0, headingHeight + 8),
				transparency = props.transparency,
			}, rows),
		})
	end)
end

local ConfirmingPage = Roact.Component:extend("ConfirmingPage")

function ConfirmingPage:init()
	self.contentSize, self.setContentSize = Roact.createBinding(0)
	self.containerSize, self.setContainerSize = Roact.createBinding(Vector2.new(0, 0))

	self:setState({
		showingStringDiff = false,
		currentString = "",
		incomingString = "",
		showingTableDiff = false,
		oldTable = {},
		newTable = {},
	})
end

function ConfirmingPage:render()
	local conflicts = self.props.confirmData.conflicts
	local hasConflicts = conflicts ~= nil and #conflicts > 0
	local conflictSpace = if hasConflicts then CONFLICT_LIST_HEIGHT + 10 else 0

	return Theme.with(function(theme)
		local pageContent = Roact.createFragment({
			Title = e("TextLabel", {
				Text = string.format(
					"Sync changes for project '%s':",
					self.props.confirmData.serverInfo.projectName or "UNKNOWN"
				),
				FontFace = theme.Font.Thin,
				LineHeight = 1.2,
				TextSize = theme.TextSize.Body,
				TextColor3 = theme.TextColor,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTransparency = self.props.transparency,
				Size = UDim2.new(1, 0, 0, theme.TextSize.Large + 2),
				BackgroundTransparency = 1,
			}),

			Conflicts = if hasConflicts
				then e(ConflictList, {
					conflicts = conflicts,
					describeConflict = self.props.describeConflict,
					transparency = self.props.transparency,
					layoutOrder = 2,
				})
				else nil,

			PatchVisualizer = e(PatchVisualizer, {
				size = UDim2.new(1, 0, 1, -100 - conflictSpace),
				transparency = self.props.transparency,
				layoutOrder = 3,

				patchTree = self.props.patchTree,

				showStringDiff = function(currentString: string, incomingString: string)
					self:setState({
						showingStringDiff = true,
						currentString = currentString,
						incomingString = incomingString,
					})
				end,
				showTableDiff = function(oldTable: { [any]: any? }, newTable: { [any]: any? })
					self:setState({
						showingTableDiff = true,
						oldTable = oldTable,
						newTable = newTable,
					})
				end,
			}),

			Buttons = e("Frame", {
				Size = UDim2.new(1, 0, 0, 34),
				LayoutOrder = 4,
				BackgroundTransparency = 1,
			}, {
				Abort = e(TextButton, {
					text = "Abort",
					style = "Bordered",
					transparency = self.props.transparency,
					layoutOrder = 1,
					onClick = self.props.onAbort,
				}, {
					Tip = e(Tooltip.Trigger, {
						text = "Stop the connection process",
					}),
				}),

				Reject = if Settings:get("twoWaySync")
					then e(TextButton, {
						text = "Reject",
						style = "Bordered",
						transparency = self.props.transparency,
						layoutOrder = 2,
						onClick = self.props.onReject,
					}, {
						Tip = e(Tooltip.Trigger, {
							text = "Push Studio changes to the Rojo server",
						}),
					})
					else nil,

				Overwrite = if hasConflicts
					then e(TextButton, {
						text = "Overwrite",
						style = "Bordered",
						transparency = self.props.transparency,
						layoutOrder = 3,
						onClick = self.props.onOverwrite,
					}, {
						Tip = e(Tooltip.Trigger, {
							text = "Sync all of your changes, replacing your teammates' newer work",
						}),
					})
					else nil,

				Accept = e(TextButton, {
					text = "Accept",
					style = "Solid",
					transparency = self.props.transparency,
					layoutOrder = 4,
					onClick = self.props.onAccept,
				}, {
					Tip = e(Tooltip.Trigger, {
						text = if hasConflicts
							then "Sync your other changes, and keep your teammates' newer work"
							else "Pull Rojo server changes to Studio",
					}),
				}),

				Layout = e("UIListLayout", {
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					FillDirection = Enum.FillDirection.Horizontal,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 10),
				}),
			}),

			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
			}),

			Layout = e("UIListLayout", {
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 10),
			}),

			StringDiff = e(StudioPluginGui, {
				id = "Rojo_ConfirmingStringDiff",
				title = "String diff",
				active = self.state.showingStringDiff,
				isEphemeral = true,

				initDockState = Enum.InitialDockState.Float,
				overridePreviousState = true,
				floatingSize = Vector2.new(500, 350),
				minimumSize = Vector2.new(400, 250),

				zIndexBehavior = Enum.ZIndexBehavior.Sibling,

				onClose = function()
					self:setState({
						showingStringDiff = false,
					})
				end,
			}, {
				TooltipsProvider = e(Tooltip.Provider, nil, {
					Tooltips = e(Tooltip.Container, nil),
					Content = e("Frame", {
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
					}, {
						e(StringDiffVisualizer, {
							size = UDim2.new(1, -10, 1, -10),
							position = UDim2.new(0, 5, 0, 5),
							anchorPoint = Vector2.new(0, 0),
							transparency = self.props.transparency,

							currentString = self.state.currentString,
							incomingString = self.state.incomingString,
						}),
					}),
				}),
			}),

			TableDiff = e(StudioPluginGui, {
				id = "Rojo_ConfirmingTableDiff",
				title = "Table diff",
				active = self.state.showingTableDiff,
				isEphemeral = true,

				initDockState = Enum.InitialDockState.Float,
				overridePreviousState = true,
				floatingSize = Vector2.new(500, 350),
				minimumSize = Vector2.new(400, 250),

				zIndexBehavior = Enum.ZIndexBehavior.Sibling,

				onClose = function()
					self:setState({
						showingTableDiff = false,
					})
				end,
			}, {
				TooltipsProvider = e(Tooltip.Provider, nil, {
					Tooltips = e(Tooltip.Container, nil),
					Content = e("Frame", {
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
					}, {
						e(TableDiffVisualizer, {
							size = UDim2.new(1, -10, 1, -10),
							position = UDim2.new(0, 5, 0, 5),
							anchorPoint = Vector2.new(0, 0),
							transparency = self.props.transparency,

							oldTable = self.state.oldTable,
							newTable = self.state.newTable,
						}),
					}),
				}),
			}),
		})

		if self.props.createPopup then
			return e(StudioPluginGui, {
				id = "Rojo_DiffSync",
				title = string.format(
					"Confirm sync for project '%s':",
					self.props.confirmData.serverInfo.projectName or "UNKNOWN"
				),
				active = true,
				isEphemeral = true,

				initDockState = Enum.InitialDockState.Float,
				overridePreviousState = false,
				floatingSize = Vector2.new(500, 350),
				minimumSize = Vector2.new(400, 250),

				zIndexBehavior = Enum.ZIndexBehavior.Sibling,

				onClose = self.props.onAbort,
			}, {
				Tooltips = e(Tooltip.Container, nil),
				Content = e("Frame", {
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
				}, pageContent),
			})
		end

		return pageContent
	end)
end

return ConfirmingPage
