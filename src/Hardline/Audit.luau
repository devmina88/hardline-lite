-- Hardline Audit
-- Finds every remote a client can reach and reports which ones are not protected.

local Audit = {}

local REMOTE_CLASSES = {
	RemoteEvent = true,
	UnreliableRemoteEvent = true,
	RemoteFunction = true,
}

-- Containers a client can see. Server-only containers
-- (ServerStorage, ServerScriptService) are skipped on purpose.
local CLIENT_VISIBLE = {
	"ReplicatedStorage",
	"ReplicatedFirst",
	"Workspace",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"Lighting",
	"Teams",
	"Players",
}

export type Status = "protected" | "ignored" | "honeypot" | "unprotected"

export type Report = {
	total: number,
	protected: { Instance },
	ignored: { Instance },
	honeypots: { Instance },
	unprotected: { Instance },
}

function Audit.run(classify: (remote: Instance) -> Status): Report
	local report: Report = {
		total = 0,
		protected = {},
		ignored = {},
		honeypots = {},
		unprotected = {},
	}

	for _, serviceName in ipairs(CLIENT_VISIBLE) do
		local ok, service = pcall(game.GetService, game, serviceName)
		if ok and service then
			for _, item in ipairs(service:GetDescendants()) do
				if REMOTE_CLASSES[item.ClassName] then
					local status = classify(item)
					if status == "honeypot" then
						table.insert(report.honeypots, item)
					else
						report.total += 1
						if status == "protected" then
							table.insert(report.protected, item)
						elseif status == "ignored" then
							table.insert(report.ignored, item)
						else
							table.insert(report.unprotected, item)
						end
					end
				end
			end
		end
	end

	return report
end

function Audit.print(report: Report, tip: string?)
	local lines = {
		`[Hardline Audit] {report.total} remotes found | {#report.protected} protected | {#report.ignored} ignored | {#report.unprotected} UNPROTECTED`,
	}

	for _, remote in ipairs(report.unprotected) do
		table.insert(lines, `  UNPROTECTED: {remote:GetFullName()} ({remote.ClassName})`)
	end

	if #report.honeypots > 0 then
		table.insert(lines, `  Honeypots active: {#report.honeypots}`)
	end

	if #report.unprotected > 0 then
		table.insert(lines, "  Protect them with Hardline.connect / Hardline.connectFunction,")
		table.insert(lines, "  or mark server-to-client-only remotes with Hardline.ignore(remote).")
		if tip then
			table.insert(lines, tip)
		end
		warn(table.concat(lines, "\n"))
	else
		print(table.concat(lines, "\n"))
	end
end

return Audit
